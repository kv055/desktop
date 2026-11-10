//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GRDB

extension DatabaseSchema {
    /// Convert full WebDAV parent URLs in item rows and queued item JSON to Files or Trash paths.
    static func migrateParentURLsToDAVRelativeLocations(in db: Database) throws {
        try migrateItemParentURLsToDAVRelativeLocations(in: db)

        // Update the queued JSON in SQLite so a malformed session ID does not stop the migration.
        let migrateSnapshot = DatabaseFunction("migrate_change_delivery_snapshot", argumentCount: 1) { values in
            guard let data = Data.fromDatabaseValue(values[0]),
                  let migrated = try ChangeDeliveryItemRecord.migrateLegacySnapshot(data)
            else { return values[0] }
            return migrated
        }
        db.add(function: migrateSnapshot)
        defer { db.remove(function: migrateSnapshot) }
        try db.execute(sql: "UPDATE changeDeliveryItem SET metadataData = migrate_change_delivery_snapshot(metadataData)")
    }

    /// Replace each item's full WebDAV parent URL with a `files:` or `trash:` path.
    /// If a domain account is supplied, use its details to fill missing account fields on matching rows.
    static func migrateItemParentURLsToDAVRelativeLocations(
        in db: Database,
        fillingMissingDetailsFrom domainAccount: DAVAccountIdentity? = nil
    ) throws {
        let columns = ItemMetadataRecord.Columns.self
        var candidates = ItemMetadataRecord.select([
            Column.rowID,
            columns.ocId,
            columns.account,
            columns.serverUrl,
            columns.fileName,
            columns.urlBase,
            columns.userId
        ])
        if let domainAccount {
            candidates = candidates
                .filter(
                    columns.account == ""
                        || columns.user == ""
                        || columns.urlBase == ""
                        || columns.userId == ""
                )
                .filter(columns.account == "" || columns.account == domainAccount.accountKey)
                .filter(columns.user == "" || columns.user == domainAccount.username)
                .filter(columns.urlBase == "" || columns.urlBase == domainAccount.serverBaseURL)
                .filter(columns.userId == "" || columns.userId == domainAccount.backendUserID)
        }
        let batchSize = FilesDatabaseManager.inClauseChunkSize
        let updateItemParent = try db.cachedStatement(sql: """
            UPDATE itemMetadata
            SET account = :account,
                serverUrl = :storedParentLocation,
                normalizedServerUrl = :normalizedParentLocation,
                urlBase = :accountBaseURL,
                user = coalesce(:username, user),
                userId = :backendUserID,
                fileName = coalesce(:rootName, fileName),
                fileNameView = coalesce(:rootName, fileNameView),
                normalizedFileName = coalesce(:rootName, normalizedFileName),
                directory = directory OR (:rootName IS NOT NULL)
            WHERE rowid = :rowID
            """)

        // Read one batch before writing it. SQLite's integer row ID remains usable even if an ocId is damaged.
        let batch = candidates.order(Column.rowID).limit(batchSize)
        var rows = try Row.fetchAll(db, batch)
        while let last = rows.last {
            for row in rows {
                do {
                    try migrateItemParentToDAVRelativeLocation(
                        row,
                        using: updateItemParent,
                        fillingMissingDetailsFrom: domainAccount
                    )
                } catch is RowDecodingError {
                    // Leave unreadable rows for a later server refresh.
                    continue
                }
            }
            let lastRowID: Int64 = last["rowid"]
            rows = try Row.fetchAll(db, batch.filter(Column.rowID > lastRowID))
        }
    }

    private static func migrateItemParentToDAVRelativeLocation(
        _ row: Row,
        using updateItemParent: Statement,
        fillingMissingDetailsFrom domainAccount: DAVAccountIdentity?
    ) throws {
        let rowID: Int64 = row["rowid"]
        let ocId: String = try row.decode(forColumn: "ocId")
        var account: String = try row.decode(forColumn: "account")
        let parentURL: String = try row.decode(forColumn: "serverUrl")
        let fileName: String = try row.decode(forColumn: "fileName")
        var accountBaseURL: String = try row.decode(forColumn: "urlBase")
        var backendUserID: String = try row.decode(forColumn: "userId")
        var username: String?
        let parentIsRelative = Account.isStoredDAVRelativeLocation(parentURL)
        if let domainAccount {
            // A relative path no longer contains the server or backend ID. Use the row's values to verify its DAV root.
            if parentIsRelative {
                guard accountBaseURL.utf8.elementsEqual(domainAccount.serverBaseURL.utf8),
                      backendUserID.utf8.elementsEqual(domainAccount.backendUserID.utf8)
                else { return }
            }
            account = domainAccount.accountKey
            accountBaseURL = domainAccount.serverBaseURL
            backendUserID = domainAccount.backendUserID
            username = domainAccount.username
        } else if accountBaseURL.isEmpty,
                  backendUserID.isEmpty,
                  let legacyAccount = ItemMetadataRecord.recoverServerBaseAndUserIDForLegacyContainer(
                      ocId: ocId,
                      account: account,
                      parentURL: parentURL
                  ) {
            accountBaseURL = legacyAccount.serverBaseURL
            backendUserID = legacyAccount.backendUserID
            username = String(account.dropLast(accountBaseURL.count + 1))
        }

        // Older rows may store the installation path, such as /nextcloud, as it appeared in the DAV response.
        let isRoot = Account.isFilesRootAddress(
            parentURL: parentURL,
            fileName: fileName,
            accountBaseURL: accountBaseURL,
            backendUserID: backendUserID,
            acceptEquivalentResponseWebroot: true
        )
        let relativeParentPath = if isRoot {
            Account.storedFilesRootLocation
        } else if parentIsRelative, domainAccount != nil {
            parentURL
        } else {
            Account.davRelativePath(
                forURL: parentURL,
                accountBaseURL: accountBaseURL,
                backendUserID: backendUserID,
                acceptEquivalentResponseWebroot: true
            )
        }
        guard let storedParentLocation = relativeParentPath else { return }
        if domainAccount != nil, storedParentLocation.split(separator: "/").contains("..") {
            return
        }
        try updateItemParent.execute(arguments: [
            "account": account,
            "storedParentLocation": storedParentLocation,
            "normalizedParentLocation": storedParentLocation.precomposedStringWithCanonicalMapping,
            "accountBaseURL": accountBaseURL,
            "username": username,
            "backendUserID": backendUserID,
            "rowID": rowID,
            "rootName": isRoot ? SendableItemMetadata.filesRootPlaceholderName : nil
        ])
    }
}
