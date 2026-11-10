//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: LGPL-3.0-or-later

import FileProvider
import Foundation
@testable import NextcloudFileProviderKit
import NextcloudFileProviderKitMocks
import NextcloudKit
import Testing
import TestInterface

extension DatabaseTestSuites {
    @Suite("Item recovery after a server URL change")
    struct DAVServerRecoveryTests {
        private struct PreviousServerFile {
            let account = DatabaseTestSuites.account
            let itemID = "file-after-server-url-change"
            let fileName = "Report.txt"
            let manager: FilesDatabaseManager
            let log = FileProviderLogMock()

            var currentURL: String { account.davFilesUrl + "/" + fileName }

            init(directory: URL) throws {
                let previousAccount = Account(
                    user: account.username,
                    id: account.id,
                    serverUrl: "https://previous.example.invalid",
                    password: account.password
                )
                let domain = NSFileProviderDomainIdentifier(directory.lastPathComponent)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var previousMetadata = DatabaseTestSuites.makeFile(ocId: itemID, fileName: fileName, account: previousAccount)
                previousMetadata.downloaded = true
                previousMetadata.keepDownloaded = true
                let storeURL = directory.appendingPathComponent(domain.rawValue).appendingPathExtension(DatabaseSchema.fileExtension)
                _ = try FilesDatabaseManager.writeVersionOneStoreForTesting(at: storeURL, metadata: [previousMetadata])
                manager = try FilesDatabaseManager(
                    account: account,
                    databaseDirectory: directory,
                    fileProviderDomainIdentifier: domain,
                    log: log,
                    defaults: DatabaseTestSuites.defaults
                )
            }

            func makeRemote(etag: String = "current-etag") -> MockRemoteInterface {
                let root = MockRemoteItem.rootItem(account: account)
                let file = MockRemoteItem(
                    identifier: itemID,
                    versionIdentifier: etag,
                    name: fileName,
                    remotePath: currentURL,
                    account: account.ncKitAccount,
                    username: account.username,
                    userId: account.id,
                    serverUrl: account.serverUrl
                )
                root.children = [file]
                file.parent = root
                return MockRemoteInterface(account: account, rootItem: root)
            }
        }

        @Test func inFlightTargetReadKeepsMetadataRecoveredByDirectoryListing() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try PreviousServerFile(directory: directory)
            let earlierServerResponse = fixture.makeRemote(etag: "earlier-etag")
            let laterServerResponse = fixture.makeRemote(etag: "later-etag")

            let (requestStarted, requestStartedContinuation) = AsyncStream<Void>.makeStream()
            let (releaseResponse, releaseResponseContinuation) = AsyncStream<Void>.makeStream()
            earlierServerResponse.enumerateHandler = {
                requestStartedContinuation.yield(())
                var iterator = releaseResponse.makeAsyncIterator()
                _ = await iterator.next()
            }
            let earlierRead = Task {
                await Enumerator.readServerUrl(
                    fixture.currentURL,
                    account: fixture.account,
                    remoteInterface: earlierServerResponse,
                    dbManager: fixture.manager,
                    depth: .target,
                    log: fixture.log
                )
            }
            defer {
                earlierRead.cancel()
                requestStartedContinuation.finish()
                releaseResponseContinuation.finish()
            }

            let didStart = try await nextTestValue(from: requestStarted)
            try #require(didStart != nil)
            let listing = await Enumerator.readServerUrl(
                fixture.account.davFilesUrl,
                account: fixture.account,
                remoteInterface: laterServerResponse,
                dbManager: fixture.manager,
                depth: .targetAndDirectChildren,
                log: fixture.log
            )
            try #require(listing.error == nil)
            try #require(listing.metadatas?.first { $0.ocId == fixture.itemID }?.etag == "later-etag")
            releaseResponseContinuation.finish()

            let result = try await testTaskValue(of: earlierRead)
            #expect(result.error == nil)
            #expect(result.metadatas?.first?.etag == "later-etag")
            let saved = try #require(fixture.manager.itemMetadata(ocId: fixture.itemID))
            #expect(saved.etag == "later-etag")
            #expect(saved.downloaded && saved.keepDownloaded)
        }
    }
}
