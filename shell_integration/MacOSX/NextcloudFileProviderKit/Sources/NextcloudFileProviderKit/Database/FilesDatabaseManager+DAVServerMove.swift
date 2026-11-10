//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

// Recover item metadata when the account's server URL changes, for example from
// https://old.example.com to https://new.example.com, and an older extension
// already saved the new URL in the domain settings without updating its database.
//
// On upgrade, the database migration can remove the old WebDAV prefix using the
// URL on each row. Older databases relied on the domain settings to identify
// the previous account. If those settings already point to the new server, startup
// leaves the old rows tied to the previous server URL.
//
// A normal directory listing can find the same item ID and type on the current
// server. Update that row to use the current account while preserving its local
// download and upload state.

@preconcurrency import FileProvider
import Foundation
import GRDB
import NextcloudKit

extension FilesDatabaseManager {
    enum ItemMetadataLookupResult {
        case currentAccount(SendableItemMetadata)
        case awaitingDirectoryListing
        case missing
    }

    /// Find previous-server IDs before a single-item read so its response cannot overwrite a row
    /// that a directory listing recovers while the request is in flight.
    func previousServerItemIDs(atCurrentURL url: String) -> Set<String> {
        guard let path = account.davRelativePath(forURL: url),
              !Account.isStoredTrashLocation(path),
              let fileName = path.split(separator: "/").last,
              let separator = path[..<fileName.startIndex].lastIndex(of: "/")
        else { return [] }

        let parentAndFileName = ItemMetadataRecord.matchesStoredParentLocationAndFileName(
            parentLocation: String(path[..<separator]),
            fileName: String(fileName)
        )
        return read("Could not look up previous-server item IDs at the requested URL.", [.url: url]) { db in
            let rows = try ItemMetadataRecord
                .filter(parentAndFileName && rowsFromPreviousServer && !ItemMetadataRecord.isFilesRoot)
                .fetchRecords(db, logger: logger)
            return Set(rows.filter(isPreviousServerFilesRow).map(\.ocId))
        } ?? []
    }

    /// Read the database for this ID, including rows that still belong to the previous server.
    /// Use one database snapshot so a concurrent recovery cannot move the row between the queries.
    func lookupItemMetadataIncludingPreviousServerRows(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> ItemMetadataLookupResult {
        let ocId = identifier.rawValue
        let lookup = read("Could not read item metadata for the current or previous server.", [.item: ocId]) { db -> ItemMetadataLookupResult in
            if let current = try itemMetadata(ocId: ocId, in: db) {
                return .currentAccount(current.metadata)
            }
            return try hasItemAwaitingDirectoryListing(ocId: ocId, in: db) ? .awaitingDirectoryListing : .missing
        }
        guard let lookup else { throw NSFileProviderError(.cannotSynchronize) }
        return lookup
    }

    func hasItemAwaitingDirectoryListing(ocId: String, in db: Database) throws -> Bool {
        let previousServerFiles = rowsFromPreviousServer && !ItemMetadataRecord.isFilesRoot
        guard let old = try ItemMetadataRecord
            .filter(key: ocId)
            .filter(previousServerFiles || legacyRowsWithOutdatedDAVAccount)
            .fetchRecord(db, logger: logger)
        else { return false }
        return old.storedParentPath == nil || isPreviousServerFilesRow(old)
    }

    /// Use only current rows for network reads. An unconvertible absolute URL leaves the scan
    /// incomplete, so Finder retries from the same change anchor.
    func itemMetadataForWorkingSetChangeScan() -> (
        items: [SendableItemMetadata],
        hasOutdatedAbsoluteURLs: Bool
    )? {
        read("Could not read the working set for a change scan.") { db in
            (
                try materialisedItemMetadatas(in: db),
                try hasMaterializedItemsWithOutdatedLegacyDAVAccount(in: db)
            )
        }
    }

    private func hasMaterializedItemsWithOutdatedLegacyDAVAccount(in db: Database) throws -> Bool {
        try !ItemMetadataRecord
            .filter(legacyRowsWithOutdatedDAVAccount && ItemMetadataRecord.isMaterialised)
            .isEmpty(db)
    }

    /// Wait for directory listings to recover any materialized items from the previous server.
    /// Finder could treat an omitted item as deleted if we returned an incomplete snapshot.
    func itemMetadataForWorkingSetSnapshot() -> [SendableItemMetadata]? {
        read("Could not read the working set snapshot.") { db -> [SendableItemMetadata]? in
            guard try !hasMaterializedItemsWithOutdatedLegacyDAVAccount(in: db) else { return nil }
            let oldRows = try ItemMetadataRecord
                .filter(rowsFromPreviousServer && ItemMetadataRecord.isMaterialised && !ItemMetadataRecord.isFilesRoot)
                .fetchRecords(db, logger: logger)
            guard !oldRows.contains(where: isPreviousServerFilesRow) else { return nil }
            return try materialisedItemMetadatas(in: db)
        } ?? nil
    }

    // These live rows still use absolute URLs that the migration could not convert. The account
    // key ties them to this domain, but the remaining details do not identify its current DAV root.
    private var legacyRowsWithOutdatedDAVAccount: SQLExpression {
        let columns = ItemMetadataRecord.Columns.self
        return !ItemMetadataRecord.hasStoredDAVRelativeParent
            && columns.account == account.ncKitAccount
            && !matchesDomainDAVAccountIncludingLegacyURLs
            && !columns.deleted
            && !columns.isLockFileOfLocalOrigin
    }

    private func isPreviousServerFilesRow(_ row: ItemMetadataRecord) -> Bool {
        guard let path = row.storedParentPath else { return false }
        return !Account.isStoredTrashLocation(path)
            && row.account.utf8.elementsEqual(Account.ncKitAccountString(from: row.user, serverUrl: row.urlBase).utf8)
            && !(path + "/" + row.fileName).split(separator: "/").contains("..")
    }

    // A directory listing can match an old row only for the same login and backend user ID.
    private var rowsFromPreviousServer: SQLExpression {
        let columns = ItemMetadataRecord.Columns.self
        return ItemMetadataRecord.hasStoredDAVRelativeParent
            && columns.user == account.username
            && columns.userId == account.id
            && columns.urlBase != account.serverUrl
            && columns.urlBase != ""
            && !columns.deleted
            && !columns.isLockFileOfLocalOrigin
    }

    /// Match an item in a directory listing to a row from the previous server by its ID and type.
    /// A child listed under its current parent can move. The listed directory itself and any item
    /// with an unfinished upload must still match the cached path.
    func previousServerRowMatchingDirectoryListing(
        _ metadata: SendableItemMetadata,
        listedUnder directoryURL: String? = nil,
        in db: Database
    ) throws -> ItemMetadataRecord? {
        let previous = try ItemMetadataRecord
            .filter(key: metadata.ocId)
            .filter(rowsFromPreviousServer)
            .fetchRecord(db, logger: logger)
        guard let previous else { return nil }

        let parentPath = account.davRelativePath(forURL: metadata.serverUrl)
        let samePath = parentPath == previous.storedParentPath && previous.fileName == metadata.fileName
        let matchesListingDirectory = directoryURL.map {
            account.hasSameDAVPath(metadata.serverUrl, $0)
                && !metadata.fileName.isEmpty
                && !metadata.fileName.contains("/")
                && account.ownsDAVReadURL(metadata.remotePath(), sourceMetadata: metadata)
        } ?? true
        guard isPreviousServerFilesRow(previous),
              metadata.account.utf8.elementsEqual(account.ncKitAccount.utf8),
              metadata.urlBase.utf8.elementsEqual(account.serverUrl.utf8),
              metadata.userId.utf8.elementsEqual(account.id.utf8),
              previous.directory == metadata.directory,
              let parentPath,
              !Account.isStoredTrashLocation(parentPath),
              matchesListingDirectory,
              samePath || (directoryURL != nil && !previous.hasUnfinishedUpload)
        else {
            // An upsert by ocId would otherwise overwrite the old row and its local state.
            throw NKError.invalidData
        }
        return previous
    }

    /// Use the server response and keep local state from the database row, including the download
    /// flag, "Always keep downloaded" setting and visited-folder flag.
    func mergeServerResponseWithPreviousServerRow(
        _ previous: ItemMetadataRecord,
        using metadata: SendableItemMetadata
    ) -> SendableItemMetadata {
        if previous.hasUnfinishedUpload {
            // The server returned its own copy. Keep the local edit's metadata and upload
            // bookkeeping so the upload can resume. Clear the lock token issued by the previous server.
            var pending = previous.metadata
            pending.apply(account: account)
            pending.serverUrl = metadata.serverUrl
            pending.fileName = metadata.fileName
            pending.lockToken = nil
            pending.syncTime = metadata.syncTime
            return pending
        }

        var updated = metadata
        updated.downloaded = previous.downloaded
        updated.keepDownloaded = previous.keepDownloaded
        updated.visitedDirectory = previous.visitedDirectory
        // Keep the version Finder already knows if the server still reports the same content.
        if previous.etag == updated.etag {
            updated.fileProviderContentVersion = previous.fileProviderContentVersion
        }
        return updated
    }
}
