//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

@preconcurrency import FileProvider
import Foundation
import GRDB
@testable import NextcloudFileProviderKit
import Testing

@Suite("Persisted DAV paths")
struct DAVPathPersistenceTests {
    private static let currentAccount = Account(
        user: "new-login",
        id: "new-id",
        serverUrl: "https://new.example.com/nextcloud",
        password: "password"
    )
    private static let fileId = "report-id"
    private static let fileName = "Report #1.txt"

    private let directory: URL
    private let domain = NSFileProviderDomainIdentifier("dav-paths-\(UUID().uuidString)")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(domain.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func legacyRowsWithMissingAccountDetailsUseDAVRelativeParents() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Self.currentAccount
        var report = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: account.davFilesUrl + "/Docs",
            account: account
        )
        report.urlBase = ""
        report.userId = ""
        report.downloaded = true
        report.keepDownloaded = true

        var trashed = DatabaseTestSuites.makeFile(
            ocId: "trashed",
            fileName: "trash.txt",
            serverUrl: account.trashUrl,
            account: account
        )
        trashed.account = ""
        trashed.user = ""
        trashed.userId = ""

        var missingAccountKey = DatabaseTestSuites.makeFile(
            ocId: "missing-account-key",
            fileName: "keyless.txt",
            serverUrl: report.serverUrl,
            account: account
        )
        missingAccountKey.account = ""
        missingAccountKey.downloaded = true

        var outsideRoot = report
        outsideRoot.ocId = "outside-root"
        outsideRoot.serverUrl = account.davFilesUrl + "-other/Docs"

        var differentAccount = report
        differentAccount.ocId = "different-account"
        let otherServer = Account(
            user: account.username,
            id: account.id,
            serverUrl: "https://other.example.com",
            password: "password"
        )
        differentAccount.account = otherServer.ncKitAccount
        differentAccount.serverUrl = otherServer.davFilesUrl + "/Docs"
        differentAccount.userId = otherServer.id

        let url = directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension)
        let identity = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: url,
            metadata: [report, trashed, missingAccountKey, outsideRoot, differentAccount]
        )
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.alter(table: StoreIdentityRecord.databaseTableName) { table in
                table.add(column: "accountBinding", .blob)
            }
            try DatabaseSchema.migrateItemParentURLsToDAVRelativeLocations(in: db)
            let boundIdentity = try StoreIdentityRecord.bindStoreToDAVAccount(account, previouslyConfiguredAccount: nil, in: db)
            #expect(boundIdentity == identity)

            func row(_ ocId: String) throws -> Row {
                let storedRow = try Row.fetchOne(db, sql: "SELECT * FROM itemMetadata WHERE ocId = ?", arguments: [ocId])
                return try #require(storedRow)
            }

            let storedReport = try row(report.ocId)
            #expect(storedReport["serverUrl"] as String == "files:/Docs")
            #expect(storedReport["normalizedServerUrl"] as String == "files:/Docs")
            #expect(storedReport["urlBase"] as String == account.serverUrl)
            #expect(storedReport["userId"] as String == account.id)
            #expect(storedReport["downloaded"] as Bool)
            #expect(storedReport["keepDownloaded"] as Bool)

            let storedTrash = try row(trashed.ocId)
            #expect(storedTrash["serverUrl"] as String == "trash:")
            #expect(storedTrash["account"] as String == account.ncKitAccount)
            #expect(storedTrash["user"] as String == account.username)
            #expect(storedTrash["userId"] as String == account.id)

            let storedKeyless = try row(missingAccountKey.ocId)
            #expect(storedKeyless["account"] as String == account.ncKitAccount)
            #expect(storedKeyless["serverUrl"] as String == "files:/Docs")
            #expect(try row(outsideRoot.ocId)["serverUrl"] as String == outsideRoot.serverUrl)
            #expect(try row(differentAccount.ocId)["serverUrl"] as String == differentAccount.serverUrl)
        }
    }

    @Test(arguments: [
        ("https://example.com:8443", "alicé", true),
        ("https://example.com", "alicé", false),
        ("https://example.com:8443", "alice\u{0301}", false)
    ])
    func convertsCachedSDKWebrootAliases(
        responseOrigin: String,
        responseBackendID: String,
        shouldConvert: Bool
    ) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(
            user: "alice",
            id: "alicé",
            serverUrl: "https://example.com:8443/caf%C3%A9",
            password: "password"
        )
        let responseFilesURL = responseOrigin + "/cafe\u{0301}" + Account.webDavFilesUrlSuffix
        let responseParentURL = responseFilesURL + responseBackendID + "/Docs"
        let file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: responseParentURL,
            account: account
        )
        var root = DatabaseTestSuites.makeFile(
            ocId: "cached-root",
            fileName: responseBackendID,
            serverUrl: String(responseFilesURL.dropLast()),
            account: account
        )
        root.directory = true
        let url = directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension)
        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: url,
            metadata: [file, root]
        )

        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try DatabaseSchema.migrateItemParentURLsToDAVRelativeLocations(in: db)
            let parentSQL = "SELECT serverUrl FROM itemMetadata WHERE ocId = ?"
            let storedFileParent = try String.fetchOne(db, sql: parentSQL, arguments: [file.ocId])
            let storedRootParent = try String.fetchOne(db, sql: parentSQL, arguments: [root.ocId])

            #expect(storedFileParent == (shouldConvert ? "files:/Docs" : responseParentURL))
            #expect(storedRootParent == (shouldConvert ? "files:" : root.serverUrl))
        }
    }
}
