//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GRDB

/// The single row naming the database file: a random identity minted when the file is first opened.
struct StoreIdentityRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storeIdentity"

    var id = 1
    var identity: String

    /// Update the account fields on matching cached rows and discard changes queued under the previous account.
    static func bindStoreToDAVAccount(
        _ account: Account,
        previouslyConfiguredAccount: DAVAccountIdentity?,
        in db: Database
    ) throws -> String {
        var storeIdentity = try ensure(in: db)
        let currentAccount = account.davAccountIdentity
        let accountBinding = try JSONEncoder().encode(currentAccount.serializedFields)
        // Fill missing account fields on cached rows that match the current account's DAV roots.
        try DatabaseSchema.migrateItemParentURLsToDAVRelativeLocations(in: db, fillingMissingDetailsFrom: currentAccount)
        let previousAccountBinding = try Data.fetchOne(db, sql: "SELECT accountBinding FROM storeIdentity WHERE id = 1")
        if previousAccountBinding == accountBinding {
            return storeIdentity
        }

        let sourceAccount: DAVAccountIdentity
        let sourceBackendUserID: String?
        if let previousAccountBinding {
            let fields = try? JSONDecoder().decode([String].self, from: previousAccountBinding)
            sourceAccount = fields.flatMap(DAVAccountIdentity.init(serializedFields:)) ?? currentAccount
            sourceBackendUserID = sourceAccount.backendUserID
        } else if let previouslyConfiguredAccount,
                  !previouslyConfiguredAccount.matchesByteForByte(currentAccount) {
            sourceAccount = previouslyConfiguredAccount
            sourceBackendUserID = sourceAccount.backendUserID
        } else {
            // A v1 database may have the same login and server URL with an older backend user ID.
            sourceAccount = currentAccount
            sourceBackendUserID = nil
        }

        if !sourceAccount.matchesByteForByte(currentAccount) {
            try DatabaseSchema.migrateItemParentURLsToDAVRelativeLocations(in: db, fillingMissingDetailsFrom: sourceAccount)
        }

        // A token acquired under the previous account may be invalid at the new WebDAV URL.
        try db.execute(
            sql: """
            UPDATE itemMetadata
            SET account = :currentAccountKey,
                urlBase = :currentServerURL,
                user = :currentUsername,
                userId = :currentBackendUserID,
                lockToken = CASE
                    WHEN account <> :currentAccountKey
                        OR urlBase <> :currentServerURL
                        OR userId <> :currentBackendUserID
                    THEN NULL
                    ELSE lockToken
                END
            WHERE (
                serverUrl IN ('files:', 'trash:')
                OR serverUrl GLOB 'files:/*'
                OR serverUrl GLOB 'trash:/*'
            )
                AND account = :previousAccountKey
                AND urlBase = :previousServerURL
                AND (
                    userId = :previousBackendUserID
                    OR :previousBackendUserID IS NULL
                )
                AND (
                    account <> :currentAccountKey
                    OR urlBase <> :currentServerURL
                    OR user <> :currentUsername
                    OR userId <> :currentBackendUserID
                )
            """,
            arguments: [
                "currentAccountKey": account.ncKitAccount,
                "currentServerURL": account.serverUrl,
                "currentUsername": account.username,
                "currentBackendUserID": account.id,
                "previousAccountKey": sourceAccount.accountKey,
                "previousServerURL": sourceAccount.serverBaseURL,
                "previousBackendUserID": sourceBackendUserID
            ]
        )
        let didRebaseItemRows = db.changesCount > 0
        let hasStaleQueuedChanges = if previousAccountBinding == nil && !didRebaseItemRows {
            try hasQueuedChangesForDifferentAccount(than: account, in: db)
        } else {
            false
        }

        if previousAccountBinding != nil || didRebaseItemRows || hasStaleQueuedChanges {
            // Old changes may contain deletions inferred using the previous DAV base.
            _ = try ChangeDeliveryItemRecord.deleteAll(db)
            _ = try ChangeDeliverySessionRecord.deleteAll(db)
            storeIdentity = UUID().uuidString
        }

        try db.execute(
            sql: "UPDATE storeIdentity SET accountBinding = ?, identity = ? WHERE id = 1",
            arguments: [accountBinding, storeIdentity]
        )
        return storeIdentity
    }

    private static func hasQueuedChangesForDifferentAccount(than account: Account, in db: Database) throws -> Bool {
        let snapshots = try Row.fetchCursor(
            db,
            sql: """
                SELECT metadataData, deleted
                FROM changeDeliveryItem
                JOIN changeDeliverySession USING (sessionId)
                WHERE changeDeliverySession.completed = 0
                """
        )
        let decoder = JSONDecoder()
        while let snapshot = try snapshots.next() {
            guard let data: Data = try? snapshot.decode(forColumn: "metadataData"),
                  let deleted: Bool = try? snapshot.decode(forColumn: "deleted"),
                  let metadata = try? ChangeDeliveryItemRecord.decodeMetadata(data, using: decoder)
            else { continue }

            if deleted && !account.ownsDAVReadURL(metadata.serverUrl, sourceMetadata: metadata) {
                return true
            }
            if !metadata.account.utf8.elementsEqual(account.ncKitAccount.utf8)
                || !metadata.urlBase.utf8.elementsEqual(account.serverUrl.utf8)
                || !metadata.userId.utf8.elementsEqual(account.id.utf8)
            {
                return true
            }
        }
        return false
    }

    /// The file's identity, minting one when the row is missing.
    static func ensure(in db: Database) throws -> String {
        if let record = try fetchOne(db) {
            return record.identity
        }

        let record = StoreIdentityRecord(identity: UUID().uuidString)
        try record.insert(db)
        return record.identity
    }
}
