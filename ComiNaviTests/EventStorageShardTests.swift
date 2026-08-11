import Foundation
import XCTest

@testable import ComiNavi

final class EventStorageShardTests: XCTestCase {
    func testEventAndComiketIdentifiersBothParticipateInShardPath() {
        let eventsDirectory = URL(fileURLWithPath: "/tmp/cominavi-test/events", isDirectory: true)

        let c108 = EventStorageShard(eventID: 230, comiketID: "108")
        let sameNumberDifferentEvent = EventStorageShard(eventID: 231, comiketID: "108")
        let sameEventDifferentNumber = EventStorageShard(eventID: 230, comiketID: "107")

        XCTAssertEqual(
            c108.directory(in: eventsDirectory).path,
            "/tmp/cominavi-test/events/event-230/comiket-108"
        )
        XCTAssertNotEqual(
            c108.directory(in: eventsDirectory),
            sameNumberDifferentEvent.directory(in: eventsDirectory)
        )
        XCTAssertNotEqual(
            c108.directory(in: eventsDirectory),
            sameEventDifferentNumber.directory(in: eventsDirectory)
        )
    }

    func testLegacyShardMigrationPreservesNestedUserPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComiNaviTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let shard = EventStorageShard(eventID: 190, comiketID: "104")
        let legacyPlan = shard.legacyDirectory(in: eventsDirectory)
            .appendingPathComponent("users/user-42/user-plan.sqlite")
        try FileManager.default.createDirectory(
            at: legacyPlan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedPlan = Data("preserved user plan".utf8)
        try expectedPlan.write(to: legacyPlan)

        let resolvedDirectory = try shard.resolveDirectory(in: eventsDirectory)
        let migratedPlan =
            resolvedDirectory
            .appendingPathComponent("users/user-42/user-plan.sqlite")

        XCTAssertEqual(resolvedDirectory, shard.directory(in: eventsDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlan.path))
        XCTAssertEqual(try Data(contentsOf: migratedPlan), expectedPlan)
    }

    func testExistingDestinationIsNeverOverwrittenByLegacyMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComiNaviTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        let shard = EventStorageShard(eventID: 190, comiketID: "104")
        let legacyDirectory = shard.legacyDirectory(in: eventsDirectory)
        let destinationDirectory = shard.directory(in: eventsDirectory)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacyDirectory.appendingPathComponent("user-plan.sqlite")
        )
        try Data("current".utf8).write(
            to: destinationDirectory.appendingPathComponent("user-plan.sqlite")
        )

        let resolvedDirectory = try shard.resolveDirectory(in: eventsDirectory)

        XCTAssertEqual(resolvedDirectory, destinationDirectory)
        XCTAssertEqual(
            try Data(contentsOf: destinationDirectory.appendingPathComponent("user-plan.sqlite")),
            Data("current".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testAccountDeletionRemovesOnlyMatchingApplicationSupportDataAndIsIdempotent()
        throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ComiNaviAccountCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let userA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let userB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let directoryA = try DirectoryManager.accountDirectoryName(publicUserID: userA)
        let directoryB = try DirectoryManager.accountDirectoryName(publicUserID: userB)
        let scopeA = String(directoryA.dropFirst("cominavi-".count))
        let scopeB = String(directoryB.dropFirst("cominavi-".count))

        let modernPlanA = root.appendingPathComponent(
            "events/event-230/comiket-108/users/\(directoryA)/user-plan.sqlite"
        )
        let legacyPlanA = root.appendingPathComponent(
            "events/comiket-107/users/\(directoryA)/user-plan.sqlite"
        )
        let modernPlanB = root.appendingPathComponent(
            "events/event-230/comiket-108/users/\(directoryB)/user-plan.sqlite"
        )
        let misleadingGlobal = root.appendingPathComponent(
            "CominaviCatalogs/users/\(directoryA)/catalog.sqlite"
        )
        let globalCatalog = root.appendingPathComponent(
            "CominaviCatalogs/events/c108/catalog.sqlite"
        )
        let exactFiles = [
            root.appendingPathComponent("shared-plans-\(scopeA).sqlite"),
            root.appendingPathComponent("shared-plans-\(scopeA).sqlite-wal"),
            root.appendingPathComponent("shared-plans-\(scopeA).sqlite-shm"),
            root.appendingPathComponent("shared-plans-\(scopeA).sqlite-journal"),
            root.appendingPathComponent(
                "ProfileMutations/profile-mutation-\(scopeA).json"
            ),
        ]
        let retainedFiles = [
            modernPlanB,
            misleadingGlobal,
            globalCatalog,
            root.appendingPathComponent("shared-plans-\(scopeB).sqlite"),
            root.appendingPathComponent(
                "ProfileMutations/profile-mutation-\(scopeB).json"
            ),
        ]
        for file in [modernPlanA, legacyPlanA] + exactFiles + retainedFiles {
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.path.utf8).write(to: file)
        }

        try DirectoryManager.shared.removeApplicationSupportData(
            publicUserID: userA,
            in: root,
            fileManager: fileManager
        )
        // Relaunch recovery can safely repeat the same cleanup before clearing
        // its protected receipt.
        try DirectoryManager.shared.removeApplicationSupportData(
            publicUserID: userA,
            in: root,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: modernPlanA.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyPlanA.path))
        for file in exactFiles {
            XCTAssertFalse(fileManager.fileExists(atPath: file.path), file.path)
        }
        for file in retainedFiles {
            XCTAssertTrue(fileManager.fileExists(atPath: file.path), file.path)
        }
    }

    @MainActor
    func testColdAccountDeletionClearsOnlyDeletedUsersProtectedInvitationSecrets()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComiNaviInvitationCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let userA = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let userB = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accountA = protectedInvitationAccount(userID: userA, baseDirectory: root)
        let accountB = protectedInvitationAccount(userID: userB, baseDirectory: root)
        let rawRequestA = UUID()
        let rawRequestB = UUID()
        let createdRequestA = UUID()
        let createdRequestB = UUID()
        let rawA = KeychainSharedPlanInviteCapabilityVault(account: accountA)
        let rawB = KeychainSharedPlanInviteCapabilityVault(account: accountB)
        let createdA = KeychainSharedPlanCreatedInvitationVault(account: accountA)
        let createdB = KeychainSharedPlanCreatedInvitationVault(account: accountB)

        try? await rawA.removeAll()
        try? await rawB.removeAll()
        try? await createdA.removeAll()
        try? await createdB.removeAll()
        do {
            try await rawA.save(token: "AAAAAAAAAAAA", requestID: rawRequestA)
            try await rawB.save(token: "BBBBBBBBBBBB", requestID: rawRequestB)
            try await createdA.save(makeCreatedInvitation(
                requestID: createdRequestA,
                planID: "11111111-1111-4111-8111-111111111111",
                invitationID: "33333333-3333-4333-8333-333333333333",
                token: "CCCCCCCCCCCC"
            ))
            try await createdB.save(makeCreatedInvitation(
                requestID: createdRequestB,
                planID: "22222222-2222-4222-8222-222222222222",
                invitationID: "44444444-4444-4444-8444-444444444444",
                token: "DDDDDDDDDDDD"
            ))

            // There is deliberately no live scoped SharedPlanStore here. The
            // post-202 cleanup receipt must be sufficient after a cold launch.
            try await AppData.clearDeletedAccountSharedPlanInvitationSecrets(
                publicUserID: userA,
                baseDirectory: root
            )
            try await AppData.clearDeletedAccountSharedPlanInvitationSecrets(
                publicUserID: userA,
                baseDirectory: root
            )

            let relaunchedRawA = KeychainSharedPlanInviteCapabilityVault(account: accountA)
            let relaunchedRawB = KeychainSharedPlanInviteCapabilityVault(account: accountB)
            let relaunchedCreatedA = KeychainSharedPlanCreatedInvitationVault(account: accountA)
            let relaunchedCreatedB = KeychainSharedPlanCreatedInvitationVault(account: accountB)
            let tokenA = try await relaunchedRawA.token(requestID: rawRequestA)
            let tokenB = try await relaunchedRawB.token(requestID: rawRequestB)
            let invitationsA = try await relaunchedCreatedA.loadAll()
            let invitationsB = try await relaunchedCreatedB.loadAll()
            XCTAssertNil(tokenA)
            XCTAssertEqual(tokenB, "BBBBBBBBBBBB")
            XCTAssertTrue(invitationsA.isEmpty)
            XCTAssertEqual(invitationsB[createdRequestB]?.token, "DDDDDDDDDDDD")
        } catch {
            try? await rawA.removeAll()
            try? await rawB.removeAll()
            try? await createdA.removeAll()
            try? await createdB.removeAll()
            throw error
        }
        try await rawA.removeAll()
        try await rawB.removeAll()
        try await createdA.removeAll()
        try await createdB.removeAll()
    }

    private func protectedInvitationAccount(
        userID: String,
        baseDirectory: URL
    ) -> String {
        let databaseURL = SharedPlanStore.databaseURL(
            baseDirectory: baseDirectory,
            userID: userID
        )
        return "\(AppEnvironment.current.storageNamespace).\(databaseURL.lastPathComponent)"
    }

    private func makeCreatedInvitation(
        requestID: UUID,
        planID: String,
        invitationID: String,
        token: String
    ) -> SharedPlanCreatedInvitation {
        SharedPlanCreatedInvitation(
            requestID: requestID,
            planID: planID,
            invitationID: invitationID,
            token: token,
            expiresAt: Date(timeIntervalSince1970: 2_000),
            canonicalURL: SharedPlanInvitationLink.canonicalURL(token: token)!,
            fallbackURL: SharedPlanInvitationLink.fallbackURL(token: token)!,
            receipt: SharedPlanMutationReceipt(
                requestID: requestID,
                replayed: false,
                resultRevision: 2,
                resultStatus: .active
            )
        )
    }
}
