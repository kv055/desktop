//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

@preconcurrency import FileProvider
import GRDB

extension FilesDatabaseManager {
    struct ItemToVerifyAfterDAVServerMove: Sendable {
        let ocId: String
        let isDirectory: Bool
        let currentURL: String
        let hasUnfinishedUpload: Bool
    }

    /// Find cached items from the previous server URL whose item IDs still need confirmation on the current server.
    private func hasMaterializedItemsToVerifyOnCurrentServer(in db: Database) throws -> Bool {
        try ItemMetadataRecord
            .filter(previousDAVServerRows && ItemMetadataRecord.isMaterialised && !ItemMetadataRecord.isFilesRoot)
            .fetchRecords(db, logger: logger)
            .contains { itemToVerifyAfterDAVServerMove($0) != nil }
    }

    /// In one database read, look for the item under the current account or under the previous server URL.
    func itemMetadataForFileProvider(
        _ identifier: NSFileProviderItemIdentifier,
        retryError: any Error = NSFileProviderError(.cannotSynchronize)
    ) throws -> SendableItemMetadata? {
        let ocId = identifier.rawValue
        let lookup = read("Could not look up File Provider item metadata.", [.item: ocId]) { db in
            if let current = try itemMetadata(ocId: ocId, in: db) {
                return (metadata: current.metadata as SendableItemMetadata?, needsVerification: false)
            }
            let old = try ItemMetadataRecord
                .filter(key: ocId)
                .filter(previousDAVServerRows && !ItemMetadataRecord.isFilesRoot)
                .fetchRecord(db, logger: logger)
            let hasOutdatedLegacyRow = try !ItemMetadataRecord
                .filter(key: ocId)
                .filter(legacyRowsWithOutdatedDAVAccount)
                .isEmpty(db)
            return (
                metadata: nil,
                needsVerification: hasOutdatedLegacyRow || old.flatMap(itemToVerifyAfterDAVServerMove) != nil
            )
        }
        guard let lookup, !lookup.needsVerification else { throw retryError }
        return lookup.metadata
    }

    /// A working-set enumeration must retry while it cannot account for these items.
    func hasMaterializedItemsWithOutdatedLegacyDAVAccount() -> Bool {
        read("Could not check the working set for outdated DAV account details.") { db in
            try hasMaterializedItemsWithOutdatedLegacyDAVAccount(in: db)
        } ?? true
    }

    private func hasMaterializedItemsWithOutdatedLegacyDAVAccount(in db: Database) throws -> Bool {
        try !ItemMetadataRecord
            .filter(legacyRowsWithOutdatedDAVAccount && ItemMetadataRecord.isMaterialised)
            .isEmpty(db)
    }

    /// Read a complete working set. Return `nil` if the database cannot be read or if
    /// any materialized item from a previous account still needs to be checked.
    func itemMetadataForWorkingSetSnapshot() -> [SendableItemMetadata]? {
        read("Could not read the working set snapshot.") { db -> [SendableItemMetadata]? in
            guard try !hasMaterializedItemsWithOutdatedLegacyDAVAccount(in: db),
                  try !hasMaterializedItemsToVerifyOnCurrentServer(in: db)
            else { return nil }
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

    private func itemToVerifyAfterDAVServerMove(_ row: ItemMetadataRecord) -> ItemToVerifyAfterDAVServerMove? {
        guard let path = row.storedParentPath,
              !Account.isStoredTrashLocation(path),
              row.account.utf8.elementsEqual(Account.ncKitAccountString(from: row.user, serverUrl: row.urlBase).utf8),
              let currentParentURL = Account.absoluteURL(
                  fromDAVRelativePath: path,
                  accountBaseURL: account.serverUrl,
                  backendUserID: account.id
              )
        else { return nil }

        let currentURL = currentParentURL + "/" + row.fileName
        guard account.ownsDAVReadURL(currentURL) else { return nil }
        return ItemToVerifyAfterDAVServerMove(
            ocId: row.ocId,
            isDirectory: row.directory,
            currentURL: currentURL,
            hasUnfinishedUpload: row.hasUnfinishedUpload
        )
    }

    private var previousDAVServerRows: SQLExpression {
        let columns = ItemMetadataRecord.Columns.self
        return ItemMetadataRecord.hasStoredDAVRelativeParent
            && columns.user == account.username
            && columns.userId == account.id
            && columns.urlBase != account.serverUrl
            && columns.urlBase != ""
            && !columns.deleted
            && !columns.isLockFileOfLocalOrigin
    }
}
