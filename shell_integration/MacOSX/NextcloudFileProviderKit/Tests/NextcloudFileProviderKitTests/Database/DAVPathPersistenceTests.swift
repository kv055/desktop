//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: GPL-2.0-or-later

@preconcurrency import FileProvider
import Foundation
import GRDB
@testable import NextcloudFileProviderKit
import NextcloudFileProviderKitMocks
import NextcloudKit
import Testing
import TestInterface

@Suite("Persisted DAV paths")
struct DAVPathPersistenceTests {
    enum EnumerationScope: CaseIterable {
        case workingSet
        case teamFolder

        var identifier: NSFileProviderItemIdentifier {
            switch self {
                case .workingSet: .workingSet
                case .teamFolder: .init(DAVPathPersistenceTests.folderId)
            }
        }
    }

    enum DAVAccountChange: CaseIterable {
        case serverBaseURL
        case backendUserID

        var accountAfterChange: Account {
            let old = DAVPathPersistenceTests.oldAccount
            let current = DAVPathPersistenceTests.currentAccount
            return Account(
                user: old.username,
                id: self == .backendUserID ? current.id : old.id,
                serverUrl: self == .serverBaseURL ? current.serverUrl : old.serverUrl,
                password: old.password
            )
        }
    }

    enum QueuedParentFormat: CaseIterable {
        case absoluteParentURL
        case relativeParentPath
    }

    enum DAVReadScope: CaseIterable {
        case item
        case directory
        case paginatedDirectory
    }

    enum MovedFileScenario: CaseIterable {
        case missingAtCachedPath
        case replacementAtCachedPath
        case unfinishedUpload
    }

    private static let oldAccount = Account(
        user: "old-login",
        id: "old-id",
        serverUrl: "https://old.example.com/cloud",
        password: "password"
    )
    private static let currentAccount = Account(
        user: "new-login",
        id: "new-id",
        serverUrl: "https://new.example.com/nextcloud",
        password: "password"
    )
    private static let folderId = "team-folder-id"
    private static let folderName = "Team Re\u{0301}ports"
    private static let fileId = "report-id"
    private static let fileName = "Report #1.txt"
    private static let remoteETag = "new-version"
    private static let storedETag = "old-version"

    private let directory: URL
    private let domain = NSFileProviderDomainIdentifier("dav-paths-\(UUID().uuidString)")
    private let log = FileProviderLogMock()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(domain.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func legacyDAVPathsMigrateWithoutLosingLocalState() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreign = Account(
            user: "foreign-login",
            id: "foreign-id",
            serverUrl: Self.oldAccount.serverUrl,
            password: "password"
        )
        var foreignFile = DatabaseTestSuites.makeFile(
            ocId: "foreign-file-id",
            fileName: "foreign-report.pdf",
            serverUrl: foreign.davFilesUrl + "/" + Self.folderName,
            account: foreign
        )
        foreignFile.downloaded = true
        var legacyFile = DatabaseTestSuites.makeFile(
            ocId: "legacy-file-id",
            fileName: "legacy-report.pdf",
            serverUrl: Self.oldAccount.davFilesUrl + "/" + Self.folderName,
            account: Self.oldAccount
        )
        legacyFile.urlBase = ""
        legacyFile.userId = ""
        legacyFile.downloaded = true
        let identity = try writeVersionOneStoreWithMaterializedItems(additionalMetadata: [foreignFile, legacyFile])

        let manager = try openManager()
        let folder = try #require(manager.itemMetadata(ocId: Self.folderId))
        let file = try #require(manager.itemMetadata(ocId: Self.fileId))
        let parentUrl = Self.currentAccount.davFilesUrl + "/" + Self.folderName
        let storedFolder = try #require(try manager.storedParentLocationKeysForTesting(ocId: Self.folderId))
        let storedFile = try #require(try manager.storedParentLocationKeysForTesting(ocId: Self.fileId))

        #expect(manager.storeIdentity != identity)
        #expect(storedFolder.parentLocation == "files:")
        #expect(storedFile.parentLocation == "files:/" + Self.folderName)
        #expect(storedFile.normalizedParentLocation.utf8.elementsEqual(("files:/" + Self.folderName).precomposedStringWithCanonicalMapping.utf8))
        #expect(try manager.hasLegacyItemPathColumnForTesting() == false)
        #expect(folder.serverUrl == Self.currentAccount.davFilesUrl)
        #expect(folder.visitedDirectory)
        #expect(file.serverUrl == parentUrl)
        #expect(file.davParentPathWithoutOrigin == Self.filesRootPathWithoutOrigin(for: Self.currentAccount) + "/" + Self.folderName + "/")
        #expect(file.account == Self.currentAccount.ncKitAccount)
        #expect(file.user == Self.currentAccount.username)
        #expect(file.userId == Self.currentAccount.id)
        #expect(file.urlBase == Self.currentAccount.serverUrl)
        #expect(file.downloaded)
        #expect(file.keepDownloaded)
        #expect(file.etag == Self.storedETag)
        #expect(!file.deleted)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: parentUrl + "/" + Self.fileName)?.ocId == Self.fileId)

        let migratedLegacyFile = try #require(manager.itemMetadata(locatedAtRemoteUrl: parentUrl + "/" + legacyFile.fileName))
        #expect(migratedLegacyFile.ocId == legacyFile.ocId)
        #expect(migratedLegacyFile.account == Self.currentAccount.ncKitAccount)
        #expect(migratedLegacyFile.downloaded)

        let retainedForeignFile = try #require(manager.itemMetadatas(account: foreign.ncKitAccount).first { $0.ocId == foreignFile.ocId })
        #expect(manager.itemMetadata(ocId: foreignFile.ocId) == nil)
        #expect(retainedForeignFile.remotePath() == foreignFile.remotePath())
        #expect(retainedForeignFile.account == foreign.ncKitAccount)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: parentUrl + "/" + foreignFile.fileName) == nil)
        #expect(manager.materialisedItemMetadatas()?.contains { $0.ocId == foreignFile.ocId } == false)
        let changes = try #require(manager.pendingWorkingSetChanges(since: .distantPast))
        #expect(changes.updated.contains { $0.ocId == foreignFile.ocId } == false)
        #expect(changes.deleted.contains { $0.ocId == foreignFile.ocId } == false)

        let reopened = try openManager()

        #expect(reopened.storeIdentity == manager.storeIdentity)
        #expect(reopened.itemMetadata(ocId: Self.fileId)?.remotePath() == file.remotePath())
        #expect(try reopened.storedParentLocationKeysForTesting(ocId: Self.fileId)?.parentLocation == storedFile.parentLocation)
    }

    @Test(arguments: [false, true])
    func movingLegacyMetadataIntoTheFilesRootStoresRelativeParents(movesDirectory: Bool) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Self.currentAccount
        let legacyRootURL = account.serverUrl + "/remote.php/webdav"
        var folder = DatabaseTestSuites.makeFile(
            ocId: Self.folderId,
            fileName: Self.folderName,
            serverUrl: legacyRootURL,
            account: account
        )
        folder.directory = true
        folder.uploaded = true
        folder.visitedDirectory = true
        folder.account = ""
        folder.urlBase = ""
        folder.userId = ""
        var file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: folder.remotePath(),
            account: account
        )
        file.account = ""
        file.urlBase = ""
        file.userId = ""
        file.uploaded = true
        file.downloaded = true
        file.keepDownloaded = true
        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [folder, file]
        )
        let manager = try openManager()
        try #require(manager.itemMetadata(locatedAtRemoteUrl: file.remotePath())?.ocId == file.ocId)
        try #require(try manager.storedParentLocationKeysForTesting(ocId: file.ocId)?.parentLocation == file.serverUrl)

        let destinationFileParentURL: String
        let destinationFileParentPath: String
        if movesDirectory {
            let movedChildren = try #require(manager.renameDirectoryAndPropagateToChildren(
                ocId: folder.ocId,
                newServerUrl: account.davFilesUrl,
                newFileName: folder.fileName
            ))
            destinationFileParentURL = account.davFilesUrl + "/" + folder.fileName
            destinationFileParentPath = "files:/" + folder.fileName
            #expect(try manager.storedParentLocationKeysForTesting(ocId: folder.ocId)?.parentLocation == "files:")
            #expect(movedChildren.map(\.ocId) == [file.ocId])
            let movedFolder = try #require(manager.itemMetadata(locatedAtRemoteUrl: destinationFileParentURL))
            #expect(manager.immediateChildItems(directoryMetadata: movedFolder).map(\.ocId) == [file.ocId])
        } else {
            manager.renameItemMetadata(
                ocId: file.ocId,
                newServerUrl: account.davFilesUrl,
                newFileName: file.fileName
            )
            destinationFileParentURL = account.davFilesUrl
            destinationFileParentPath = "files:"
        }

        #expect(try manager.storedParentLocationKeysForTesting(ocId: file.ocId)?.parentLocation == destinationFileParentPath)
        let movedFile = try #require(manager.itemMetadata(locatedAtRemoteUrl: destinationFileParentURL + "/" + file.fileName))
        #expect(movedFile.ocId == file.ocId)
        #expect(movedFile.account == account.ncKitAccount)
        #expect(movedFile.userId == account.id)
        #expect(movedFile.downloaded)
        #expect(movedFile.keepDownloaded)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: file.remotePath()) == nil)
    }

    @Test func unverifiedOldHostUploadSurvivesAConflictingListing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Self.currentAccount
        let oldAccount = Account(
            user: account.username,
            id: account.id,
            serverUrl: Self.oldAccount.serverUrl,
            password: account.password
        )
        var pending = DatabaseTestSuites.makeFile(ocId: Self.fileId, fileName: Self.fileName, account: oldAccount)
        pending.downloaded = true
        pending.uploaded = false
        pending.keepDownloaded = true
        pending.status = Status.uploadError.rawValue
        pending.chunkUploadId = "old-host-upload"
        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [pending]
        )
        savePreviouslyConfiguredAccount(account)

        let manager = try openManager()
        let remote = MockRemoteInterface(account: account, rootItem: .rootItem(account: account))
        let enumerator = try Enumerator(
            enumeratedItemIdentifier: .workingSet,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            log: log
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        let reported = try #require(observer.items.first as? Item)
        #expect(reported.itemIdentifier.rawValue == pending.ocId)
        #expect(reported.parentItemIdentifier == .rootContainer)
        #expect(reported.metadata.chunkUploadId == pending.chunkUploadId)

        var listedFile = DatabaseTestSuites.makeFile(
            ocId: pending.ocId,
            fileName: "A different address.txt",
            account: account
        )
        listedFile.uploaded = true
        #expect(throws: NKError.invalidData) {
            try manager.persistItemMetadataFromPagedListing(listedFile)
        }
        #expect(manager.depth1ReadUpdateItemMetadatas(
            account: account.ncKitAccount,
            serverUrl: account.davFilesUrl,
            updatedMetadatas: [listedFile],
            keepExistingDownloadState: true
        ) == nil)

        let retained = try #require(manager.itemMetadatas(account: oldAccount.ncKitAccount).first { $0.ocId == pending.ocId })
        #expect(retained.status == Status.uploadError.rawValue)
        #expect(retained.chunkUploadId == pending.chunkUploadId)
        #expect(retained.keepDownloaded)
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

        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [report, trashed, missingAccountKey, outsideRoot, differentAccount]
        )

        let manager = try openManager()
        let storedReport = try #require(try manager.storedParentLocationKeysForTesting(ocId: report.ocId))
        let restoredReport = try #require(manager.itemMetadata(locatedAtRemoteUrl: report.remotePath()))
        #expect(storedReport.parentLocation == "files:/Docs")
        #expect(storedReport.normalizedParentLocation == "files:/Docs")
        #expect(restoredReport.ocId == report.ocId)
        #expect(restoredReport.urlBase == account.serverUrl)
        #expect(restoredReport.userId == account.id)
        #expect(restoredReport.downloaded)
        #expect(restoredReport.keepDownloaded)

        let storedTrash = try #require(try manager.storedParentLocationKeysForTesting(ocId: trashed.ocId))
        let restoredTrash = try #require(manager.itemMetadata(locatedAtRemoteUrl: trashed.remotePath()))
        #expect(storedTrash.parentLocation == "trash:")
        #expect(restoredTrash.ocId == trashed.ocId)
        #expect(restoredTrash.account == account.ncKitAccount)
        #expect(restoredTrash.user == account.username)
        #expect(restoredTrash.userId == account.id)

        #expect(manager.itemMetadata(ocId: missingAccountKey.ocId)?.account == account.ncKitAccount)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: missingAccountKey.remotePath())?.ocId == missingAccountKey.ocId)
        #expect(manager.materialisedItemMetadatas()?.contains { $0.ocId == missingAccountKey.ocId } == true)

        #expect(try manager.storedParentLocationKeysForTesting(ocId: outsideRoot.ocId)?.parentLocation == outsideRoot.serverUrl)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: outsideRoot.remotePath())?.ocId == outsideRoot.ocId)
        #expect(try manager.storedParentLocationKeysForTesting(ocId: differentAccount.ocId)?.parentLocation == differentAccount.serverUrl)
        #expect(manager.itemMetadata(ocId: differentAccount.ocId) == nil)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: differentAccount.remotePath()) == nil)
        #expect(manager.materialisedItemMetadatas()?.contains { $0.ocId == differentAccount.ocId } == false)
    }

    @Test func unboundLegacyStoreOnlyRebasesRowsForTheCurrentLogin() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = Self.currentAccount
        let previousBackend = Account(
            user: current.username,
            id: Self.oldAccount.id,
            serverUrl: current.serverUrl,
            password: current.password
        )
        let oldFile = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            account: previousBackend
        )
        let foreignFile = DatabaseTestSuites.makeFile(
            ocId: "foreign-file-id",
            fileName: "foreign-report.pdf",
            account: Self.oldAccount
        )
        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [oldFile, foreignFile]
        )

        let manager = try openManager()

        #expect(manager.itemMetadata(locatedAtRemoteUrl: current.davFilesUrl + "/" + Self.fileName)?.ocId == Self.fileId)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: current.davFilesUrl + "/" + foreignFile.fileName) == nil)
        #expect(manager.itemMetadata(ocId: foreignFile.ocId) == nil)
        #expect(manager.itemMetadatas(account: Self.oldAccount.ncKitAccount).first { $0.ocId == foreignFile.ocId }?.remotePath() == foreignFile.remotePath())
    }

    @Test func legacyAccountMatchingUsesTheOriginalLoginBytes() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Account(user: "caf\u{00E9}", id: "backend-id", serverUrl: "https://example.com", password: "password")
        let current = Account(user: "cafe\u{0301}", id: previous.id, serverUrl: previous.serverUrl, password: previous.password)
        savePreviouslyConfiguredAccount(previous)

        var file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: previous.davFilesUrl + "/Docs",
            account: previous
        )
        file.urlBase = ""
        file.userId = ""

        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [file]
        )

        let manager = try openManager(account: current)
        let restored = try #require(manager.itemMetadata(ocId: file.ocId))
        #expect(restored.account.utf8.elementsEqual(current.ncKitAccount.utf8))
        #expect(try manager.storedParentLocationKeysForTesting(ocId: file.ocId)?.parentLocation == "files:/Docs")
    }

    @Test(arguments: DAVAccountChange.allCases)
    func reopeningAfterDAVAccountChangeRebuildsParentURLsAndDropsQueuedDeletions(change: DAVAccountChange) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try openManager(account: Self.oldAccount)
        let oldParent = Self.oldAccount.davFilesUrl + "/" + Self.folderName
        var file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: oldParent,
            account: Self.oldAccount
        )
        file.etag = Self.storedETag
        original.addItemMetadata(file)
        let staleSession = "pending-old-account-deletion"
        try #require(original.createChangeDeliverySession(
            sessionId: staleSession,
            containerKey: NSFileProviderItemIdentifier.workingSet.rawValue,
            anchorKey: "old-anchor",
            finalAnchorRawValue: Data(),
            updated: [],
            deleted: [file],
            incomplete: false,
            hardRemoveDeleted: true
        ))

        let stored = try #require(try original.storedParentLocationKeysForTesting(ocId: Self.fileId))
        #expect(stored.parentLocation == "files:/" + Self.folderName)

        let currentAccount = change.accountAfterChange
        let reopened = try openManager(account: currentAccount)

        #expect(reopened.storeIdentity != original.storeIdentity)
        #expect(try reopened.changeDeliverySession(sessionId: staleSession) == nil)
        let reopenedFile = try #require(reopened.itemMetadata(ocId: Self.fileId))
        #expect(!reopenedFile.deleted)
        #expect(reopenedFile.etag == Self.storedETag)
        #expect(reopenedFile.davParentPathWithoutOrigin == Self.filesRootPathWithoutOrigin(for: currentAccount) + "/" + Self.folderName + "/")
        #expect(reopenedFile.remotePath() == currentAccount.davFilesUrl + "/" + Self.folderName + "/" + Self.fileName)
    }

    @Test(arguments: [false, true])
    func legacyQueuedUpdateReplaysWithAnAbsoluteParentURL(equivalentWebroot: Bool) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = equivalentWebroot
            ? Account(
                user: "alice",
                id: "alice",
                serverUrl: "https://example.com/caf%C3%A9",
                password: "password"
            )
            : Self.currentAccount
        let file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: account.davFilesUrl + "/Docs",
            account: account
        )
        var cachedFile = file
        if equivalentWebroot {
            cachedFile.serverUrl = "https://example.com/cafe\u{0301}" + Account.webDavFilesUrlSuffix + account.id + "/Docs"
        }
        let sessionId = "queued-update"
        let identity = try FilesDatabaseManager.writeVersionOneStoreWithQueuedUpdateForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: cachedFile,
            legacyPath: Self.filesRootPathWithoutOrigin(for: account) + "/Docs/",
            sessionId: sessionId
        )

        let manager = try openManager(account: account)

        #expect(manager.storeIdentity == identity)
        #expect(try manager.hasLegacyItemPathColumnForTesting() == false)
        #expect(manager.itemMetadata(ocId: file.ocId)?.remotePath() == file.remotePath())
        let change = try #require(manager.changeDeliveryItems(sessionId: sessionId, fromSequence: 0, limit: 1)?.first)
        let snapshot = try #require(JSONSerialization.jsonObject(with: change.metadataData) as? [String: Any])
        #expect(snapshot["path"] == nil)
        #expect(snapshot["serverUrl"] == nil)
        #expect(snapshot["parentDAVPath"] as? String == "files:/Docs")
        try expectQueuedUpdateReplays(from: manager, file: file, sessionId: sessionId)
    }

    @Test func malformedQueueKeysDoNotPreventOtherChangesFromMigrating() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            account: Self.currentAccount
        )
        let url = directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension)
        let sessionId = "queued-update"
        _ = try FilesDatabaseManager.writeVersionOneStoreWithQueuedUpdateForTesting(
            at: url,
            metadata: file,
            legacyPath: Self.filesRootPathWithoutOrigin(for: Self.currentAccount) + "/",
            sessionId: sessionId
        )

        var staleFile = file
        staleFile.apply(account: Self.oldAccount)
        staleFile.serverUrl = Self.oldAccount.davFilesUrl
        let staleSnapshot = try JSONEncoder().encode(staleFile)

        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(
                sql: """
                    INSERT INTO changeDeliveryItem (sessionId, sequence, metadataData, deleted)
                    VALUES (CAST(X'FE' AS TEXT), 0, ?, 1)
                    """,
                arguments: [staleSnapshot]
            )
            try db.execute(sql: """
                INSERT INTO changeDeliveryItem (sessionId, sequence, metadataData, deleted)
                VALUES (CAST(X'FF' AS TEXT), 0, X'FF', 0)
                """)
        }

        let manager = try openManager()
        try expectQueuedUpdateReplays(from: manager, file: file, sessionId: sessionId)
    }

    @Test(arguments: QueuedParentFormat.allCases)
    func queuedParentsReplayFromAbsoluteURLAndRelativePath(format: QueuedParentFormat) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try openManager()
        let account = Self.currentAccount
        let file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: account.davFilesUrl + "/Docs",
            account: account
        )
        let sessionId = "queued-update"
        let encodedMetadata = try JSONEncoder().encode(file)
        var snapshot = try #require(JSONSerialization.jsonObject(with: encodedMetadata) as? [String: Any])
        switch format {
            case .absoluteParentURL:
                snapshot["path"] = file.davParentPathWithoutOrigin
            case .relativeParentPath:
                snapshot.removeValue(forKey: "serverUrl")
                snapshot["parentDAVPath"] = "files:/Docs"
        }
        let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)

        try manager.writer.write { db in
            try ChangeDeliverySessionRecord(
                sessionId: sessionId,
                containerKey: "working-set",
                currentAnchorKey: "old-anchor",
                finalAnchorRawValue: Data(),
                incomplete: false,
                hardRemoveDeleted: false
            ).insert(db)
            try ChangeDeliveryItemRecord(
                sessionId: sessionId,
                sequence: 0,
                metadataData: snapshotData,
                deleted: false
            ).insert(db)
        }

        try expectQueuedUpdateReplays(from: manager, file: file, sessionId: sessionId)
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

        let manager = try openManager(account: account)
        let storedFileParent = try manager.storedParentLocationKeysForTesting(ocId: file.ocId)
        let storedRootParent = try manager.storedParentLocationKeysForTesting(ocId: root.ocId)

        #expect(storedFileParent?.parentLocation == (shouldConvert ? "files:/Docs" : responseParentURL))
        #expect(storedRootParent?.parentLocation == (shouldConvert ? "files:" : root.serverUrl))

        let byURL = manager.itemMetadata(locatedAtRemoteUrl: account.davFilesUrl + "/Docs/" + file.fileName)
        #expect(byURL?.ocId == (shouldConvert ? file.ocId : nil))
        if shouldConvert {
            let restoredRoot = manager.rootItemMetadata()
            #expect(restoredRoot?.ocId == root.ocId)
            #expect(restoredRoot?.remotePath() == account.davFilesUrl)
        }
    }

    private func expectQueuedUpdateReplays(
        from manager: FilesDatabaseManager,
        file: SendableItemMetadata,
        sessionId: String
    ) throws {
        let buffer = ChangeDeliveryBuffer(
            dbManager: manager,
            containerKey: "working-set",
            hardRemoveDeleted: false,
            log: log
        )
        try #require(try buffer.isPrimed(forKey: "old-anchor"))
        let batch = try #require(buffer.prepareChangeDeliveryBatch(maxItems: 1))
        #expect(batch.updated.map(\.ocId) == [file.ocId])
        #expect(batch.updated.map { $0.remotePath() } == [file.remotePath()])
        #expect(batch.deleted.isEmpty)
        #expect(!batch.moreComing)
        buffer.acknowledgeBatch(batch.acknowledgement)
        #expect(try manager.changeDeliverySession(sessionId: sessionId) == nil)
    }

    @Test(arguments: [false, true])
    func migratesBothRootFormsWithoutChangingTheItemID(usesNextcloudKitRootPlaceholder: Bool) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Account(
            user: "old-id",
            id: "old-id",
            serverUrl: "https://old.example.com/",
            password: "password"
        )
        let filesParentURL = "https://old.example.com" + String(Account.webDavFilesUrlSuffix.dropLast())
        var root = DatabaseTestSuites.makeFile(
            ocId: "server-root-id",
            fileName: usesNextcloudKitRootPlaceholder ? NextcloudKit.shared.nkCommonInstance.rootFileName : old.id,
            serverUrl: usesNextcloudKitRootPlaceholder ? filesParentURL + "/" + old.id : filesParentURL,
            account: old
        )
        root.directory = !usesNextcloudKitRootPlaceholder
        root.keepDownloaded = true
        _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [root],
            legacyPaths: [root.ocId: Account.webDavFilesUrlSuffix]
        )

        let account = Self.currentAccount
        savePreviouslyConfiguredAccount(old)
        let manager = try openManager()
        let migrated = try #require(manager.rootItemMetadata())
        let stored = try #require(try manager.storedParentLocationKeysForTesting(ocId: root.ocId))

        #expect(stored.parentLocation == "files:")
        #expect(migrated.account == account.ncKitAccount)
        #expect(migrated.ocId == root.ocId)
        #expect(migrated.directory)
        #expect(migrated.keepDownloaded)
        #expect(migrated.fileName == "/")
        #expect(migrated.remotePath() == account.davFilesUrl)
        #expect(manager.itemMetadata(locatedAtRemoteUrl: account.davFilesUrl)?.ocId == root.ocId)

        var synthetic = migrated
        synthetic.ocId = NSFileProviderItemIdentifier.rootContainer.rawValue
        manager.addItemMetadata(synthetic)

        var child = DatabaseTestSuites.makeFile(ocId: Self.folderId, fileName: account.id, account: account)
        child.directory = true
        child.uploaded = true
        let changes = try #require(manager.depth1ReadUpdateItemMetadatas(
            account: account.ncKitAccount,
            serverUrl: account.davFilesUrl,
            updatedMetadatas: [migrated, child],
            keepExistingDownloadState: true
        ))
        #expect(changes.deleted.isEmpty)
        #expect(manager.immediateChildItems(directoryMetadata: migrated).map(\.ocId) == [child.ocId])
        #expect(manager.childItemCount(directoryMetadata: migrated) == 1)

        let reopened = try openManager()
        #expect(reopened.itemMetadata(ocId: root.ocId)?.deleted == false)
        #expect(reopened.itemMetadata(ocId: synthetic.ocId)?.deleted == false)
    }

    @Test(arguments: EnumerationScope.allCases)
    func enumerationReadsExistingItemsAtTheCurrentDAVBase(container: EnumerationScope) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeVersionOneStoreWithMaterializedItems()
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let folderUrl = Self.currentAccount.davFilesUrl + "/" + Self.folderName
        remote.enumerateCallHandler = { path, _, _, _, _, _, _, _ in
            #expect(path == folderUrl || path == folderUrl + "/" + Self.fileName)
        }

        let observer = try await enumerateChanges(in: container, manager: manager, remote: remote)

        #expect(remote.readOperationCount > 0)
        #expect(observer.changedItems.contains { $0.itemIdentifier.rawValue == Self.fileId })
        #expect(observer.deletedItemIdentifiers.isEmpty)
        let file = try #require(manager.itemMetadata(ocId: Self.fileId))
        #expect(file.etag == Self.remoteETag)
        #expect(!file.deleted)
        #expect(file.downloaded)
        #expect(file.keepDownloaded)
    }

    @Test(arguments: EnumerationScope.allCases)
    func aMissingItemAtTheCurrentDAVBaseStillReportsDeletion(container: EnumerationScope) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeVersionOneStoreWithMaterializedItems()
        let manager = try openManager()
        let remote = MockRemoteInterface(account: Self.currentAccount, rootItem: .rootItem(account: Self.currentAccount))
        let folderUrl = Self.currentAccount.davFilesUrl + "/" + Self.folderName
        remote.enumerateCallHandler = { path, _, _, _, _, _, _, _ in
            #expect(path == folderUrl || path == folderUrl + "/" + Self.fileName)
        }

        let observer = try await enumerateChanges(in: container, manager: manager, remote: remote)

        #expect(remote.readOperationCount > 0)
        #expect(observer.deletedItemIdentifiers.contains(.init(Self.folderId)))
    }

    @Test(arguments: [true, false])
    func workingSetWaitsForDirectoryListingWithMatchingItemID(itemIDMatches: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Self.currentAccount
        let previous = try writeLegacyStoreWithOutdatedDAVHost()
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let remoteFile = try #require(remote.rootItem?.children.first?.children.first)
        if !itemIDMatches {
            remoteFile.identifier = "replacement-item"
        }
        let folderURL = account.davFilesUrl + "/" + Self.folderName
        remote.enumerateCallHandler = { path, depth, _, _, _, _, _, _ in
            #expect(path == folderURL)
            #expect(depth == .targetAndDirectChildren)
        }

        let observer = try await enumerateChanges(in: .workingSet, manager: manager, remote: remote)
        #expect(remote.readOperationCount == 0)
        #expect(observer.changedItems.isEmpty)
        #expect(observer.deletedItemIdentifiers.isEmpty)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)

        let listing = await listDirectory(folderURL, manager: manager, remote: remote)
        #expect(listing.error == nil)
        #expect(remote.readOperationCount == 1)
        #expect(listing.changes?.deleted.isEmpty == true)
        if itemIDMatches {
            let recovered = try #require(manager.itemMetadata(ocId: Self.fileId))
            #expect(recovered.remotePath() == remoteFile.remotePath)
            #expect(recovered.downloaded)
            #expect(recovered.keepDownloaded)
            #expect(recovered.etag == Self.remoteETag)
            #expect(listing.changes?.updated.contains { $0.ocId == Self.fileId } == true)
        } else {
            #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
            let oldRow = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
            #expect(!oldRow.deleted)
            #expect(oldRow.downloaded)
            #expect(listing.metadatas?.contains { $0.ocId == remoteFile.identifier } == true)
        }
    }

    @Test func directoryReadReportsRecoveredDownloadAndPinFlags() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeLegacyStoreWithOutdatedDAVHost()
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let account = Self.currentAccount

        let result = await Enumerator.readServerUrl(
            account.davFilesUrl + "/" + Self.folderName,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .targetAndDirectChildren,
            log: log
        )

        #expect(result.error == nil)
        let reported = try #require(result.metadatas?.first { $0.ocId == Self.fileId })
        let saved = try #require(manager.itemMetadata(ocId: Self.fileId))
        #expect(reported.downloaded && saved.downloaded)
        #expect(reported.keepDownloaded && saved.keepDownloaded)
        #expect(result.changes?.updated.contains { $0.ocId == Self.fileId } == true)
    }

    @Test(arguments: [false, true])
    func targetReadLeavesPreviousServerRowUnchanged(fileMoved: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try writeLegacyStoreWithOutdatedDAVHost()
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let file = try #require(remote.rootItem?.children.first?.children.first)
        let account = Self.currentAccount
        if fileMoved {
            file.name = "Renamed report.txt"
            file.remotePath = account.davFilesUrl + "/" + Self.folderName + "/" + file.name
        }

        let result = await Enumerator.readServerUrl(
            file.remotePath,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .target,
            log: log
        )

        #expect(result.error == .invalidData)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
        let oldRow = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
        #expect(oldRow.fileName == Self.fileName)
        #expect(oldRow.downloaded && oldRow.keepDownloaded)
    }

    @Test func finderWaitsForDirectoryListingsBeforeOpeningOnlineOnlyItems() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try writeLegacyStoreWithOutdatedDAVHost(materialised: false)
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let account = Self.currentAccount
        let fileID = NSFileProviderItemIdentifier(Self.fileId)
        let folderID = NSFileProviderItemIdentifier(Self.folderId)
        let folderURL = account.davFilesUrl + "/" + Self.folderName

        func lookupFile() async throws -> Item {
            try await Item.lookupResolvingParent(
                identifier: fileID,
                account: account,
                remoteInterface: remote,
                dbManager: manager,
                log: log
            )
        }

        func openFolder() throws -> Enumerator {
            try Enumerator(
                enumeratedItemIdentifier: folderID,
                account: account,
                remoteInterface: remote,
                dbManager: manager,
                log: log
            )
        }

        await #expect(throws: NSFileProviderError(.cannotSynchronize)) {
            try await lookupFile()
        }
        #expect(throws: NSFileProviderError(.cannotSynchronize)) {
            try openFolder()
        }
        #expect(remote.readOperationCount == 0)
        #expect(manager.itemMetadatas(account: previous.ncKitAccount).contains { $0.ocId == Self.fileId && !$0.deleted })

        let rootListing = await listDirectory(account.davFilesUrl, manager: manager, remote: remote)
        #expect(rootListing.error == nil)
        #expect(manager.itemMetadata(ocId: Self.folderId)?.remotePath() == folderURL)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
        #expect(remote.readOperationCount == 1)

        let observer = MockEnumerationObserver(enumerator: try openFolder())
        try await observer.enumerateItems()
        #expect(observer.items.contains { $0.itemIdentifier == fileID })
        #expect(remote.readOperationCount == 2)

        let file = try await lookupFile()
        #expect(file.metadata.remotePath() == folderURL + "/" + Self.fileName)
        #expect(!file.metadata.downloaded)
        #expect(file.parentItemIdentifier == folderID)
        #expect(remote.readOperationCount == 2)
    }

    @Test(arguments: MovedFileScenario.allCases, [false, true])
    func directoryListingRecoversMovedFileFromPreviousServer(
        scenario: MovedFileScenario,
        paginated: Bool
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let hasUnfinishedUpload = scenario == .unfinishedUpload
        let previous = try writeLegacyStoreWithOutdatedDAVHost(fileUploadFailed: hasUnfinishedUpload)
        let manager = try openManager()
        let account = Self.currentAccount
        let remote = makeRemoteWithTeamFolder()
        let folder = try #require(remote.rootItem?.children.first)
        let oldPathOnCurrentServer = try #require(folder.children.first?.remotePath)
        let destination = account.davFilesUrl + "/Moved report.txt"
        let move = await remote.move(
            remotePathSource: oldPathOnCurrentServer,
            remotePathDestination: destination,
            account: account
        )
        try #require(move.error == .success)
        if scenario == .replacementAtCachedPath {
            let replacement = MockRemoteItem(
                identifier: "replacement-item",
                name: Self.fileName,
                remotePath: oldPathOnCurrentServer,
                account: account.ncKitAccount,
                username: account.username,
                userId: account.id,
                serverUrl: account.serverUrl
            )
            replacement.parent = folder
            folder.children = [replacement]
        }
        let workingSet = try Enumerator(
            enumeratedItemIdentifier: .workingSet,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            log: log
        )
        let firstSnapshot = MockEnumerationObserver(enumerator: workingSet)
        try await firstSnapshot.enumerateItems()
        #expect(remote.readOperationCount == 0)
        let retained = try #require(firstSnapshot.items.first { $0.itemIdentifier.rawValue == Self.fileId } as? Item)
        #expect(retained.parentItemIdentifier.rawValue == Self.folderId)
        #expect(retained.metadata.downloaded)
        #expect(retained.metadata.keepDownloaded)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)

        let pageSettings: (page: NSFileProviderPage?, index: Int, size: Int)?
        if paginated {
            remote.pagination = true
            let pageSize = 2
            let firstPage = await Enumerator.readServerUrl(
                account.davFilesUrl,
                pageSettings: (nil, 0, pageSize),
                account: account,
                remoteInterface: remote,
                dbManager: manager,
                depth: .targetAndDirectChildren,
                log: log
            )
            try #require(firstPage.error == nil)
            #expect(firstPage.metadatas?.map(\.ocId) == [Self.folderId])
            let continuation = try #require(firstPage.nextPage)
            let token = try #require(continuation.token)
            pageSettings = (NSFileProviderPage(Data(token.utf8)), continuation.index, pageSize)
        } else {
            pageSettings = nil
        }
        let listing = await Enumerator.readServerUrl(
            account.davFilesUrl,
            pageSettings: pageSettings,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .targetAndDirectChildren,
            log: log
        )

        if hasUnfinishedUpload {
            #expect(listing.error != nil)
            #expect(listing.metadatas == nil)
            #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
            let saved = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
            #expect(saved.remotePath() == retained.metadata.remotePath())
            #expect(saved.status == Status.uploadError.rawValue)
            #expect(saved.chunkUploadId == "pending-edit-upload")
            #expect(saved.etag == Self.storedETag)
            #expect(saved.downloaded)
            #expect(saved.keepDownloaded)
            #expect(!saved.uploaded)
            #expect(!saved.deleted)
            return
        }

        #expect(listing.error == nil)
        let listedFile = try #require(listing.metadatas?.first { $0.ocId == Self.fileId })
        #expect(listedFile.remotePath() == destination)
        #expect(listedFile.downloaded)
        #expect(listedFile.keepDownloaded)
        #expect(manager.itemMetadata(ocId: Self.fileId)?.remotePath() == destination)

        let nextSnapshot = MockEnumerationObserver(enumerator: workingSet)
        try await nextSnapshot.enumerateItems()
        let reported = try #require(nextSnapshot.items.first { $0.itemIdentifier.rawValue == Self.fileId } as? Item)
        #expect(reported.parentItemIdentifier == .rootContainer)
        #expect(reported.metadata.remotePath() == destination)
    }

    @Test(arguments: [false, true])
    func listingMovedPreviousServerFolderAsTargetKeepsItsCachedRow(paginated: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try writeLegacyStoreWithOutdatedDAVHost()
        let manager = try openManager()
        let account = Self.currentAccount
        let remote = makeRemoteWithTeamFolder()
        let folder = try #require(remote.rootItem?.children.first)
        let destination = account.davFilesUrl + "/Renamed team folder"
        let move = await remote.move(
            remotePathSource: folder.remotePath,
            remotePathDestination: destination,
            account: account
        )
        try #require(move.error == .success)

        let listing = await Enumerator.readServerUrl(
            destination,
            pageSettings: paginated ? (nil, 0, 10) : nil,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .targetAndDirectChildren,
            log: log
        )

        #expect(listing.error != nil)
        #expect(listing.metadatas == nil)
        #expect(manager.itemMetadata(ocId: Self.folderId) == nil)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
        let cached = manager.itemMetadatas(account: previous.ncKitAccount)
        let cachedFolder = try #require(cached.first { $0.ocId == Self.folderId })
        #expect(cachedFolder.remotePath() == previous.davFilesUrl + "/" + Self.folderName)
        #expect(cachedFolder.visitedDirectory)
        let cachedFile = try #require(cached.first { $0.ocId == Self.fileId })
        #expect(cachedFile.downloaded)
        #expect(cachedFile.keepDownloaded)
    }

    @Test(arguments: [false, true])
    func workingSetKeepsOriginalWhenCachedPathNamesAnotherItem(fileUploadFailed: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try writeLegacyStoreWithOutdatedDAVHost(fileUploadFailed: fileUploadFailed)
        let manager = try openManager()
        let account = Self.currentAccount
        let seeded = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
        var healthy = DatabaseTestSuites.makeFile(ocId: "current-file", fileName: "Current.txt", account: account)
        healthy.downloaded = true
        healthy.uploaded = true
        manager.addItemMetadata(healthy)

        let remote = makeRemoteWithTeamFolder()
        let root = try #require(remote.rootItem)
        let replacement = try #require(root.children.first?.children.first)
        replacement.identifier = "replacement-item"
        let currentFile = MockRemoteItem(
            identifier: healthy.ocId,
            name: healthy.fileName,
            remotePath: healthy.remotePath(),
            account: account.ncKitAccount,
            username: account.username,
            userId: account.id,
            serverUrl: account.serverUrl
        )
        currentFile.parent = root
        root.children.append(currentFile)
        let enumerator = try Enumerator(
            enumeratedItemIdentifier: .workingSet,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            log: log
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)

        try await observer.enumerateItems()

        #expect(observer.items.contains { $0.itemIdentifier.rawValue == healthy.ocId })
        #expect(!observer.items.contains { $0.itemIdentifier.rawValue == replacement.identifier })
        let retained = try #require(observer.items.first { $0.itemIdentifier.rawValue == Self.fileId } as? Item)
        #expect(retained.parentItemIdentifier.rawValue == Self.folderId)
        #expect(retained.metadata.downloaded)
        #expect(retained.metadata.keepDownloaded)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
        let saved = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
        #expect(saved.status == (fileUploadFailed ? Status.uploadError.rawValue : Status.normal.rawValue))
        #expect(saved.chunkUploadId == seeded.chunkUploadId)
        #expect(!saved.deleted)

        #expect(remote.readOperationCount == 0)

        // Listing Files rebinds the old parent. A different enumerator must still know its ID.
        let rootListing = await listDirectory(account.davFilesUrl, manager: manager, remote: remote)
        try #require(rootListing.error == nil)
        try #require(manager.itemMetadata(ocId: Self.folderId) != nil)
        let newEnumerator = try Enumerator(
            enumeratedItemIdentifier: .workingSet,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            log: log
        )
        let nextSnapshot = MockEnumerationObserver(enumerator: newEnumerator)
        try await nextSnapshot.enumerateItems()
        let original = try #require(nextSnapshot.items.first { $0.itemIdentifier.rawValue == Self.fileId })
        #expect(original.parentItemIdentifier.rawValue == Self.folderId)
        #expect(nextSnapshot.items.contains { $0.itemIdentifier.rawValue == healthy.ocId })
        #expect(remote.readOperationCount == 1)

        // Browsing can discover the replacement independently. A snapshot cannot publish both IDs
        // under the same name and parent, so Finder must retry while the original is unresolved.
        manager.addItemMetadata(replacement.toItemMetadata(account: account))
        try #require(manager.itemMetadata(ocId: replacement.identifier) != nil)
        let collision = MockEnumerationObserver(enumerator: newEnumerator)
        await #expect(throws: NSFileProviderError(.cannotSynchronize)) {
            try await collision.enumerateItems()
        }
        #expect(collision.items.isEmpty)
        #expect(manager.itemMetadatas(account: previous.ncKitAccount).contains { $0.ocId == Self.fileId && !$0.deleted })
    }

    @Test(arguments: DAVReadScope.allCases, [true, false])
    func onlyDirectoryListingAtCachedPathRecoversPendingUpload(
        scope: DAVReadScope,
        pathMatches: Bool
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Self.currentAccount
        let previous = try writeLegacyStoreWithOutdatedDAVHost(fileUploadFailed: true)
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let folderURL = account.davFilesUrl + "/" + Self.folderName
        let remoteFile = try #require(remote.rootItem?.children.first?.children.first)
        if !pathMatches {
            remoteFile.name = "Renamed report.txt"
            remoteFile.remotePath = folderURL + "/" + remoteFile.name
        }

        let result = await Enumerator.readServerUrl(
            scope == .item ? remoteFile.remotePath : folderURL,
            pageSettings: scope == .paginatedDirectory ? (nil, 0, 10) : nil,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: scope == .item ? .target : .targetAndDirectChildren,
            log: log
        )

        let saved: SendableItemMetadata
        if scope != .item, pathMatches {
            #expect(result.error == nil)
            let reported = try #require(result.metadatas?.first { $0.ocId == Self.fileId })
            #expect(reported.status == Status.uploadError.rawValue)
            #expect(reported.etag == Self.storedETag)
            saved = try #require(manager.itemMetadata(ocId: Self.fileId))
            #expect(saved.remotePath() == remoteFile.remotePath)
        } else {
            #expect(result.error != nil)
            #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
            saved = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
            #expect(saved.remotePath() == previous.davFilesUrl + "/" + Self.folderName + "/" + Self.fileName)
        }
        #expect(saved.status == Status.uploadError.rawValue)
        #expect(!saved.uploaded)
        #expect(saved.chunkUploadId == "pending-edit-upload")
        #expect(saved.keepDownloaded)
        #expect(saved.etag == Self.storedETag)
    }

    @Test func targetReadOfPreviousServerItemKeepsCurrentItemAtSamePath() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try writeLegacyStoreWithOutdatedDAVHost()
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let account = Self.currentAccount
        let folderURL = account.davFilesUrl + "/" + Self.folderName
        let fileURL = folderURL + "/" + Self.fileName
        let replacement = DatabaseTestSuites.makeFile(
            ocId: "replacement-id",
            fileName: Self.fileName,
            serverUrl: folderURL,
            account: account
        )
        // The database already contains a different live item at the requested path.
        manager.addItemMetadata(replacement)
        try #require(manager.itemMetadata(locatedAtRemoteUrl: fileURL)?.ocId == replacement.ocId)

        let result = await Enumerator.readServerUrl(
            fileURL,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .target,
            log: log
        )

        #expect(result.error == .invalidData)
        #expect(manager.itemMetadata(ocId: Self.fileId) == nil)
        #expect(manager.itemMetadata(ocId: replacement.ocId)?.deleted == false)
        let retained = try #require(manager.itemMetadatas(account: previous.ncKitAccount).first { $0.ocId == Self.fileId })
        #expect(retained.downloaded && retained.keepDownloaded)
    }

    @Test(arguments: [true, false])
    func fullListingPreservesRecoveredPendingUploadAfterServerMove(movesToRoot: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeLegacyStoreWithOutdatedDAVHost(fileUploadFailed: true)
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let account = Self.currentAccount
        let folderURL = account.davFilesUrl + "/" + Self.folderName
        let initialListing = await listDirectory(folderURL, manager: manager, remote: remote)
        try #require(initialListing.error == nil)
        try #require(manager.itemMetadata(ocId: Self.fileId)?.hasUnfinishedUpload == true)

        let root = try #require(remote.rootItem)
        let folder = try #require(root.children.first)
        let file = try #require(folder.children.first)
        let originalURL = file.remotePath
        let destination = movesToRoot ? root : folder
        if movesToRoot {
            folder.children = []
            root.children.append(file)
            file.parent = root
        } else {
            file.name = "Renamed report.txt"
        }
        file.remotePath = destination.remotePath + "/" + file.name

        let result = await Enumerator.readServerUrl(
            destination.remotePath,
            account: account,
            remoteInterface: remote,
            dbManager: manager,
            depth: .targetAndDirectChildren,
            log: log
        )

        #expect(result.error == .metadataDatabaseWriteFailed)
        let saved = try #require(manager.itemMetadata(ocId: Self.fileId))
        #expect(saved.remotePath() == originalURL)
        #expect(saved.status == Status.uploadError.rawValue)
        #expect(saved.chunkUploadId == "pending-edit-upload")
        #expect(saved.etag == Self.storedETag)
    }

    @Test func directoryListingAndSubsequentReadsPreservePendingUpload() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeLegacyStoreWithOutdatedDAVHost(fileUploadFailed: true)
        let manager = try openManager()
        let remote = makeRemoteWithTeamFolder()
        let account = Self.currentAccount
        let folder = try #require(remote.rootItem?.children.first)
        let addedFile = MockRemoteItem(
            identifier: "new-team-file",
            name: "New file.txt",
            remotePath: folder.remotePath + "/New file.txt",
            account: account.ncKitAccount,
            username: account.username,
            userId: account.id,
            serverUrl: account.serverUrl
        )
        addedFile.parent = folder
        folder.children.append(addedFile)

        let folderURL = account.davFilesUrl + "/" + Self.folderName
        let listing = await listDirectory(folderURL, manager: manager, remote: remote)
        #expect(listing.error == nil)
        #expect(listing.changes?.deleted.isEmpty == true)
        #expect(listing.changes?.updated.contains { $0.ocId == Self.fileId } == true)
        #expect(listing.changes?.created.contains { $0.ocId == addedFile.identifier } == true)
        let fileURL = folderURL + "/" + Self.fileName
        let reads: [(String, EnumerateDepth)] = [
            (folderURL, .targetAndDirectChildren),
            (fileURL, .target)
        ]
        for (url, depth) in reads {
            let result = await Enumerator.readServerUrl(
                url,
                account: account,
                remoteInterface: remote,
                dbManager: manager,
                depth: depth,
                log: log
            )
            #expect(result.error == nil)
            let reported = try #require(result.metadatas?.first { $0.ocId == Self.fileId })
            #expect(reported.status == Status.uploadError.rawValue)
            #expect(reported.etag == Self.storedETag)
        }
        let saved = try #require(manager.itemMetadata(ocId: Self.fileId))
        #expect(saved.status == Status.uploadError.rawValue)
        #expect(saved.chunkUploadId == "pending-edit-upload")
        #expect(saved.etag == Self.storedETag)
    }

    private func writeLegacyStoreWithOutdatedDAVHost(
        fileUploadFailed: Bool = false,
        materialised: Bool = true
    ) throws -> Account {
        let current = Self.currentAccount
        let previous = Account(
            user: current.username,
            id: current.id,
            serverUrl: "https://previous.example.com/cloud",
            password: current.password
        )
        _ = try writeVersionOneStoreWithMaterializedItems(
            oldAccount: previous,
            fileUploadFailed: fileUploadFailed,
            materialised: materialised
        )
        // Recreate the state left by an older extension after a server URL change.
        // The domain settings use the current URL, but the v1 database still has the previous URL.
        savePreviouslyConfiguredAccount(current)
        return previous
    }

    private func writeVersionOneStoreWithMaterializedItems(
        oldAccount: Account = Self.oldAccount,
        additionalMetadata: [SendableItemMetadata] = [],
        fileUploadFailed: Bool = false,
        materialised: Bool = true
    ) throws -> String {
        savePreviouslyConfiguredAccount(oldAccount)
        let oldParent = oldAccount.davFilesUrl + "/" + Self.folderName
        var folder = DatabaseTestSuites.makeFile(
            ocId: Self.folderId,
            fileName: Self.folderName,
            account: oldAccount
        )
        folder.directory = true
        folder.visitedDirectory = materialised
        folder.uploaded = true
        folder.etag = Self.storedETag
        var file = DatabaseTestSuites.makeFile(
            ocId: Self.fileId,
            fileName: Self.fileName,
            serverUrl: oldParent,
            account: oldAccount
        )
        file.downloaded = materialised
        file.uploaded = true
        file.keepDownloaded = materialised
        file.etag = Self.storedETag
        if fileUploadFailed {
            file.uploaded = false
            file.status = Status.uploadError.rawValue
            file.chunkUploadId = "pending-edit-upload"
        }
        return try FilesDatabaseManager.writeVersionOneStoreForTesting(
            at: directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension),
            metadata: [folder, file] + additionalMetadata,
            legacyPaths: [
                Self.folderId: oldAccount.davFilesUrl,
                Self.fileId: Self.filesRootPathWithoutOrigin(for: oldAccount) + "/" + Self.folderName + "/"
            ]
        )
    }

    private func savePreviouslyConfiguredAccount(_ account: Account) {
        var defaults = FileProviderDomainDefaults(identifier: domain, log: log, defaults: DatabaseTestSuites.defaults)
        defaults.serverUrl = account.serverUrl
        defaults.user = account.username
        defaults.userId = account.id
    }

    private func openManager(account: Account = Self.currentAccount) throws -> FilesDatabaseManager {
        try FilesDatabaseManager(
            account: account,
            databaseDirectory: directory,
            fileProviderDomainIdentifier: domain,
            log: log,
            defaults: DatabaseTestSuites.defaults
        )
    }

    private static func filesRootPathWithoutOrigin(for account: Account) -> String {
        URL(string: account.serverUrl)!.path + Account.webDavFilesUrlSuffix + account.id
    }

    private func makeRemoteWithTeamFolder() -> MockRemoteInterface {
        let account = Self.currentAccount
        let root = MockRemoteItem.rootItem(account: account)
        let folder = MockRemoteItem(
            identifier: Self.folderId,
            versionIdentifier: Self.remoteETag,
            name: Self.folderName,
            remotePath: account.davFilesUrl + "/" + Self.folderName,
            directory: true,
            account: account.ncKitAccount,
            username: account.username,
            userId: account.id,
            serverUrl: account.serverUrl
        )
        let file = MockRemoteItem(
            identifier: Self.fileId,
            versionIdentifier: Self.remoteETag,
            name: Self.fileName,
            remotePath: folder.remotePath + "/" + Self.fileName,
            account: account.ncKitAccount,
            username: account.username,
            userId: account.id,
            serverUrl: account.serverUrl
        )
        root.children = [folder]
        folder.parent = root
        folder.children = [file]
        file.parent = folder
        return MockRemoteInterface(account: account, rootItem: root)
    }

    private func listDirectory(
        _ url: String,
        manager: FilesDatabaseManager,
        remote: MockRemoteInterface
    ) async -> RemoteReadResult {
        await Enumerator.readServerUrl(
            url,
            account: Self.currentAccount,
            remoteInterface: remote,
            dbManager: manager,
            depth: .targetAndDirectChildren,
            log: log
        )
    }

    private func enumerateChanges(
        in container: EnumerationScope,
        manager: FilesDatabaseManager,
        remote: MockRemoteInterface
    ) async throws -> MockChangeObserver {
        let enumerator = try Enumerator(
            enumeratedItemIdentifier: container.identifier,
            account: Self.currentAccount,
            remoteInterface: remote,
            dbManager: manager,
            log: log
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        let anchor = Enumerator.syncAnchor(at: Date(timeIntervalSinceNow: -60), storeIdentity: manager.storeIdentity)
        try await observer.enumerateChanges(from: anchor)
        return observer
    }
}
