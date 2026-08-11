import Foundation
import GRDB

struct ArchivedSharedPlanRecovery: Equatable, Sendable {
    let id: UUID
    let snapshot: SharedPlanDocumentSnapshot
    let metadataIntents: [SharedPlanRESTWrite]

    init(
        id: UUID,
        snapshot: SharedPlanDocumentSnapshot,
        metadataIntents: [SharedPlanRESTWrite] = []
    ) {
        self.id = id
        self.snapshot = snapshot
        self.metadataIntents = metadataIntents
    }
}

protocol SharedPlanPersisting: Sendable {
    func replicaID() async throws -> UUID
    func loadPlans() async throws -> [SharedPlan]
    func loadRESTWrites() async throws -> [SharedPlanRESTWrite]
    func loadDocument(planID: String) async throws -> SharedPlanDocumentSnapshot?
    func loadOrphanedDocuments(
        excludingPlanIDs: Set<String>
    ) async throws -> [SharedPlanDocumentSnapshot]
    func loadArchivedRecoveryDocuments() async throws -> [ArchivedSharedPlanRecovery]
    func loadNotifications() async throws -> [SharedPlanNotificationItem]
    func loadNotificationReadIntents() async throws -> [String]
    func loadMemoDrafts(planID: String) async throws -> [SharedPlanMemoDraft]
    func saveRESTWrite(_ write: SharedPlanRESTWrite) async throws
    func saveNotifications(_ notifications: [SharedPlanNotificationItem]) async throws
    func saveNotificationReadIntent(eventID: String, createdAt: Date) async throws
    func acknowledgeNotificationRead(
        _ receipt: SharedPlanNotificationReadReceipt
    ) async throws
    func removeNotificationReadIntent(eventID: String) async throws
    func saveBootstrappedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        removingWriteID: UUID?
    ) async throws
    func saveDiscardedContentRebootstrap(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        discardingMemoDraftReplicaID: UUID
    ) async throws
    func savePlan(_ plan: SharedPlan, write: SharedPlanRESTWrite?) async throws
    func saveMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot
    ) async throws
    func saveMemoDraft(_ draft: SharedPlanMemoDraft) async throws
    func saveMemoMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        acknowledging draft: SharedPlanMemoDraft
    ) async throws
    func saveRecoveryDocument(_ document: SharedPlanDocumentSnapshot) async throws
    func replaceReinstatedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        retaining recovery: ArchivedSharedPlanRecovery
    ) async throws
    func reconcileCachedPlans(
        _ plans: [SharedPlan],
        quarantinedWrites: [SharedPlanRESTWrite],
        recoveryDocuments: [SharedPlanDocumentSnapshot]
    ) async throws
    func saveQuarantinedRESTWrites(
        _ writes: [SharedPlanRESTWrite],
        currentPlan: SharedPlan?
    ) async throws
    func replaceQuarantinedRESTWrites(
        removing writeIDs: Set<UUID>,
        with pendingWrites: [SharedPlanRESTWrite],
        plan: SharedPlan
    ) async throws
    func saveAcknowledgedPlan(
        _ plan: SharedPlan,
        removingWriteID: UUID,
        rebasedWrites: [SharedPlanRESTWrite]
    ) async throws
    func removeRESTWrite(id: UUID) async throws
    func removePlan(id: String) async throws
    func removeArchivedRecoveryDocument(id: UUID) async throws
    func removeAll() async throws
}

actor SQLiteSharedPlanPersistence: SharedPlanPersisting {
    private enum MetadataKey {
        static let replicaID = "replicaID"
    }

    private let database: DatabasePool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(path: String) throws {
        database = try DatabasePool(path: path)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        var migrator = DatabaseMigrator()
        migrator.registerMigration("create-shared-plans-v1") { database in
            try database.create(table: SharedPlanCacheRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("comiketNo", .integer).notNull().indexed()
                table.column("lifecycle", .text).notNull()
                table.column("ownership", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try database.create(table: SharedPlanDocumentRecord.databaseTableName) { table in
                table.column("planID", .text).primaryKey()
                table.column("replicaID", .text).notNull()
                table.column("actorID", .text).notNull()
                table.column("document", .blob).notNull()
                table.column("pendingOperationIDs", .blob).notNull()
                table.column("syncIssue", .blob)
                table.column("updatedAt", .datetime).notNull()
            }
            try database.create(table: SharedPlanRESTWriteRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("planID", .text).notNull().indexed()
                table.column("payload", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try database.create(table: SharedPlanMetadataRecord.databaseTableName) { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("create-shared-plan-recoveries-v2") { database in
            try database.create(
                table: SharedPlanArchivedRecoveryRecord.databaseTableName
            ) { table in
                table.column("id", .text).primaryKey()
                table.column("planID", .text).notNull().indexed()
                table.column("replicaID", .text).notNull()
                table.column("actorID", .text).notNull()
                table.column("document", .blob).notNull()
                table.column("pendingOperationIDs", .blob).notNull()
                table.column("syncIssue", .blob)
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("archive-shared-plan-intents-v3") { database in
            try database.alter(table: SharedPlanArchivedRecoveryRecord.databaseTableName) {
                $0.add(column: "metadataIntents", .blob)
            }
        }
        migrator.registerMigration("persist-shared-plan-local-edit-limits-v4") { database in
            try database.alter(table: SharedPlanDocumentRecord.databaseTableName) {
                $0.add(column: "localEditLimit", .blob)
            }
            try database.alter(table: SharedPlanArchivedRecoveryRecord.databaseTableName) {
                $0.add(column: "localEditLimit", .blob)
            }
        }
        migrator.registerMigration("create-shared-plan-notification-inbox-v5") { database in
            try database.create(table: SharedPlanNotificationRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("createdAt", .datetime).notNull().indexed()
            }
            try database.create(
                table: SharedPlanNotificationReadIntentRecord.databaseTableName
            ) { table in
                table.column("eventID", .text).primaryKey()
                table.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("create-shared-plan-memo-drafts-v6") { database in
            try database.create(table: SharedPlanMemoDraftRecord.databaseTableName) { table in
                table.column("planID", .text).notNull()
                table.column("replicaID", .text).notNull()
                table.column("comiketNo", .integer).notNull()
                table.column("wcID", .integer).notNull()
                table.column("generation", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["planID", "replicaID", "comiketNo", "wcID"])
            }
            try database.create(
                index: "sharedPlanMemoDraftByPlan",
                on: SharedPlanMemoDraftRecord.databaseTableName,
                columns: ["planID"]
            )
        }
        migrator.registerMigration("persist-offline-mutation-authority-v7") { database in
            try database.alter(table: SharedPlanDocumentRecord.databaseTableName) {
                $0.add(
                    column: "offlineMutationAuthority",
                    .boolean
                ).notNull().defaults(to: false)
            }
            try database.alter(table: SharedPlanArchivedRecoveryRecord.databaseTableName) {
                $0.add(
                    column: "offlineMutationAuthority",
                    .boolean
                ).notNull().defaults(to: false)
            }
        }
        try migrator.migrate(database)
    }

    func replicaID() async throws -> UUID {
        try await database.write { database in
            if let value = try String.fetchOne(
                database,
                sql: "SELECT value FROM sharedPlanMetadata WHERE key = ?",
                arguments: [MetadataKey.replicaID]
            ), let replicaID = UUID(uuidString: value) {
                return replicaID
            }

            let replicaID = UUID()
            try SharedPlanMetadataRecord(
                key: MetadataKey.replicaID,
                value: replicaID.uuidString.lowercased()
            ).insert(database)
            return replicaID
        }
    }

    func loadPlans() async throws -> [SharedPlan] {
        try await database.read { database in
            try SharedPlanCacheRecord
                .order(Column("updatedAt").desc)
                .fetchAll(database)
                .map { try self.decoder.decode(SharedPlan.self, from: $0.payload) }
        }
    }

    func loadRESTWrites() async throws -> [SharedPlanRESTWrite] {
        try await database.read { database in
            try SharedPlanRESTWriteRecord
                .order(Column("createdAt"))
                .fetchAll(database)
                .map { try self.decoder.decode(SharedPlanRESTWrite.self, from: $0.payload) }
        }
    }

    func loadDocument(planID: String) async throws -> SharedPlanDocumentSnapshot? {
        try await database.read { database in
            guard let record = try SharedPlanDocumentRecord.fetchOne(database, key: planID),
                  let replicaID = UUID(uuidString: record.replicaID)
            else { return nil }
            let pending = try self.decoder.decode([UUID].self, from: record.pendingOperationIDs)
            let issue = try record.syncIssue.map {
                try self.decoder.decode(SharedPlanSyncIssue.self, from: $0)
            }
            return SharedPlanDocumentSnapshot(
                planID: planID,
                replicaID: replicaID,
                actorID: record.actorID,
                document: record.document,
                pendingOperationIDs: pending,
                syncIssue: issue,
                localEditLimit: try record.localEditLimit.map {
                    try self.decoder.decode(SharedPlanLocalEditLimit.self, from: $0)
                },
                offlineMutationAuthority: record.offlineMutationAuthority
            )
        }
    }

    func loadOrphanedDocuments(
        excludingPlanIDs: Set<String>
    ) async throws -> [SharedPlanDocumentSnapshot] {
        try await database.read { database in
            let request = SharedPlanDocumentRecord.all()
            let records: [SharedPlanDocumentRecord]
            if excludingPlanIDs.isEmpty {
                records = try request.fetchAll(database)
            } else {
                records = try request
                    .filter(!Array(excludingPlanIDs).contains(Column("planID")))
                    .fetchAll(database)
            }
            return try records.map { record in
                guard let replicaID = UUID(uuidString: record.replicaID) else {
                    throw SharedPlanError.persistenceFailed
                }
                return SharedPlanDocumentSnapshot(
                    planID: record.planID,
                    replicaID: replicaID,
                    actorID: record.actorID,
                    document: record.document,
                    pendingOperationIDs: try self.decoder.decode(
                        [UUID].self,
                        from: record.pendingOperationIDs
                    ),
                    syncIssue: try record.syncIssue.map {
                        try self.decoder.decode(SharedPlanSyncIssue.self, from: $0)
                    },
                    localEditLimit: try record.localEditLimit.map {
                        try self.decoder.decode(SharedPlanLocalEditLimit.self, from: $0)
                    },
                    offlineMutationAuthority: record.offlineMutationAuthority
                )
            }
        }
    }

    func loadArchivedRecoveryDocuments() async throws -> [ArchivedSharedPlanRecovery] {
        try await database.read { database in
            try SharedPlanArchivedRecoveryRecord
                .order(Column("updatedAt").desc)
                .fetchAll(database)
                .map { record in
                    guard let id = UUID(uuidString: record.id),
                          let replicaID = UUID(uuidString: record.replicaID)
                    else { throw SharedPlanError.persistenceFailed }
                    return ArchivedSharedPlanRecovery(
                        id: id,
                        snapshot: SharedPlanDocumentSnapshot(
                            planID: record.planID,
                            replicaID: replicaID,
                            actorID: record.actorID,
                            document: record.document,
                            pendingOperationIDs: try self.decoder.decode(
                                [UUID].self,
                                from: record.pendingOperationIDs
                            ),
                            syncIssue: try record.syncIssue.map {
                                try self.decoder.decode(SharedPlanSyncIssue.self, from: $0)
                            },
                            localEditLimit: try record.localEditLimit.map {
                                try self.decoder.decode(SharedPlanLocalEditLimit.self, from: $0)
                            },
                            offlineMutationAuthority: record.offlineMutationAuthority
                        ),
                        metadataIntents: try record.metadataIntents.map {
                            try self.decoder.decode([SharedPlanRESTWrite].self, from: $0)
                        } ?? []
                    )
                }
        }
    }

    func loadNotifications() async throws -> [SharedPlanNotificationItem] {
        try await database.read { database in
            try SharedPlanNotificationRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchAll(database)
                .map {
                    try self.decoder.decode(
                        SharedPlanNotificationItem.self,
                        from: $0.payload
                    )
                }
        }
    }

    func loadNotificationReadIntents() async throws -> [String] {
        try await database.read { database in
            try SharedPlanNotificationReadIntentRecord
                .order(Column("createdAt"), Column("eventID"))
                .fetchAll(database)
                .map(\.eventID)
        }
    }

    func loadMemoDrafts(planID: String) async throws -> [SharedPlanMemoDraft] {
        try await database.read { database in
            try SharedPlanMemoDraftRecord
                .filter(Column("planID") == planID)
                .order(Column("updatedAt"), Column("replicaID"), Column("wcID"))
                .fetchAll(database)
                .map { record in
                    let draft = try self.decoder.decode(
                        SharedPlanMemoDraft.self,
                        from: record.payload
                    )
                    guard draft.planID == record.planID,
                          draft.replicaID.uuidString.lowercased() == record.replicaID,
                          draft.circle.comiketNo == record.comiketNo,
                          draft.circle.wcID == record.wcID,
                          draft.generation == UInt64(record.generation),
                          draft.generation <= UInt64(Int64.max)
                    else { throw SharedPlanError.persistenceFailed }
                    return draft
                }
        }
    }

    func savePlan(_ plan: SharedPlan, write: SharedPlanRESTWrite?) async throws {
        let planRecord = try cacheRecord(for: plan)
        let writeRecord = try write.map { try restWriteRecord(for: $0) }
        try await database.write { database in
            try planRecord.save(database)
            if let writeRecord {
                try writeRecord.save(database)
            }
        }
    }

    func saveRESTWrite(_ write: SharedPlanRESTWrite) async throws {
        let record = try restWriteRecord(for: write)
        try await database.write { database in
            try record.save(database)
        }
    }

    func saveNotifications(_ notifications: [SharedPlanNotificationItem]) async throws {
        try await database.write { database in
            for incoming in notifications {
                var notification = incoming
                if notification.readAt == nil,
                   let existing = try SharedPlanNotificationRecord.fetchOne(
                       database,
                       key: notification.id
                   )
                {
                    let persisted = try self.decoder.decode(
                        SharedPlanNotificationItem.self,
                        from: existing.payload
                    )
                    notification.readAt = persisted.readAt
                }
                try SharedPlanNotificationRecord(
                    id: notification.id,
                    payload: try self.encoder.encode(notification),
                    createdAt: notification.createdAt
                ).save(database)
            }
        }
    }

    func saveNotificationReadIntent(eventID: String, createdAt: Date) async throws {
        try await database.write { database in
            try SharedPlanNotificationReadIntentRecord(
                eventID: eventID,
                createdAt: createdAt
            ).save(database)
        }
    }

    func acknowledgeNotificationRead(
        _ receipt: SharedPlanNotificationReadReceipt
    ) async throws {
        try await database.write { database in
            guard let record = try SharedPlanNotificationRecord.fetchOne(
                database,
                key: receipt.id
            ) else { throw SharedPlanError.persistenceFailed }
            var notification = try self.decoder.decode(
                SharedPlanNotificationItem.self,
                from: record.payload
            )
            notification.readAt = notification.readAt ?? receipt.readAt
            try SharedPlanNotificationRecord(
                id: notification.id,
                payload: try self.encoder.encode(notification),
                createdAt: notification.createdAt
            ).save(database)
            _ = try SharedPlanNotificationReadIntentRecord.deleteOne(
                database,
                key: receipt.id
            )
        }
    }

    func removeNotificationReadIntent(eventID: String) async throws {
        try await database.write { database in
            _ = try SharedPlanNotificationReadIntentRecord.deleteOne(
                database,
                key: eventID
            )
        }
    }

    func saveBootstrappedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        removingWriteID: UUID?
    ) async throws {
        guard plan.id == document.planID else {
            throw SharedPlanError.persistenceFailed
        }
        let planRecord = try cacheRecord(for: plan)
        let documentRecord = try documentRecord(for: document)
        try await database.write { database in
            try planRecord.save(database)
            try documentRecord.save(database)
            if let removingWriteID {
                _ = try SharedPlanRESTWriteRecord.deleteOne(
                    database,
                    key: removingWriteID.uuidString.lowercased()
                )
            }
        }
    }

    func saveDiscardedContentRebootstrap(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        discardingMemoDraftReplicaID: UUID
    ) async throws {
        guard plan.id == document.planID,
              document.replicaID == discardingMemoDraftReplicaID
        else { throw SharedPlanError.persistenceFailed }
        let planRecord = try cacheRecord(for: plan)
        let documentRecord = try documentRecord(for: document)
        try await database.write { database in
            try planRecord.save(database)
            try documentRecord.save(database)
            _ = try SharedPlanMemoDraftRecord
                .filter(Column("planID") == plan.id)
                .filter(
                    Column("replicaID")
                        == discardingMemoDraftReplicaID.uuidString.lowercased()
                )
                .deleteAll(database)
        }
    }

    func saveMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot
    ) async throws {
        guard plan.id == document.planID else { throw SharedPlanError.persistenceFailed }
        let planRecord = try cacheRecord(for: plan)
        let documentRecord = try documentRecord(for: document)
        // The visible cache, Automerge bytes, stable replica/actor identity, and
        // durable semantic operation IDs commit in one SQLite transaction.
        try await database.write { database in
            try planRecord.save(database)
            try documentRecord.save(database)
        }
    }

    func saveMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        let record = try memoDraftRecord(for: draft)
        try await database.write { database in
            if let storedGeneration = try Int64.fetchOne(
                database,
                sql: """
                SELECT generation FROM sharedPlanMemoDraft
                WHERE planID = ? AND replicaID = ? AND comiketNo = ? AND wcID = ?
                """,
                arguments: [
                    record.planID,
                    record.replicaID,
                    record.comiketNo,
                    record.wcID,
                ]
            ), storedGeneration > record.generation {
                return
            }
            try record.save(database)
        }
    }

    func saveMemoMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        acknowledging draft: SharedPlanMemoDraft
    ) async throws {
        guard plan.id == document.planID,
              draft.planID == plan.id,
              draft.replicaID == document.replicaID
        else { throw SharedPlanError.persistenceFailed }
        let planRecord = try cacheRecord(for: plan)
        let documentRecord = try documentRecord(for: document)
        try await database.write { database in
            try planRecord.save(database)
            try documentRecord.save(database)
            try SharedPlanMemoDraftRecord
                .filter(Column("planID") == draft.planID)
                .filter(Column("replicaID") == draft.replicaID.uuidString.lowercased())
                .filter(Column("comiketNo") == draft.circle.comiketNo)
                .filter(Column("wcID") == draft.circle.wcID)
                .filter(Column("generation") == Int64(draft.generation))
                .deleteAll(database)
        }
    }

    func saveRecoveryDocument(_ document: SharedPlanDocumentSnapshot) async throws {
        let record = try documentRecord(for: document)
        try await database.write { database in
            try record.save(database)
        }
    }

    func replaceReinstatedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        retaining recovery: ArchivedSharedPlanRecovery
    ) async throws {
        guard plan.id == document.planID,
              recovery.snapshot.planID == plan.id,
              recovery.snapshot.replicaID != document.replicaID,
              recovery.metadataIntents.allSatisfy({
                  $0.planID == plan.id && $0.quarantineReason == .membershipRevoked
              })
        else { throw SharedPlanError.persistenceFailed }
        let planRecord = try cacheRecord(for: plan)
        let documentRecord = try documentRecord(for: document)
        let recoveryRecord = try archivedRecoveryRecord(for: recovery)
        try await database.write { database in
            try recoveryRecord.save(database)
            for intent in recovery.metadataIntents {
                _ = try SharedPlanRESTWriteRecord.deleteOne(
                    database,
                    key: intent.id.uuidString.lowercased()
                )
            }
            try planRecord.save(database)
            try documentRecord.save(database)
        }
    }

    func reconcileCachedPlans(
        _ plans: [SharedPlan],
        quarantinedWrites: [SharedPlanRESTWrite],
        recoveryDocuments: [SharedPlanDocumentSnapshot]
    ) async throws {
        let records = try plans.map { try cacheRecord(for: $0) }
        let quarantinedRecords = try quarantinedWrites.map { try restWriteRecord(for: $0) }
        let recoveryRecords = try recoveryDocuments.map { try documentRecord(for: $0) }
        let retainedIDs = records.map(\.id)
        try await database.write { database in
            if retainedIDs.isEmpty {
                try SharedPlanCacheRecord.deleteAll(database)
            } else {
                try SharedPlanCacheRecord
                    .filter(!retainedIDs.contains(Column("id")))
                    .deleteAll(database)
            }
            for record in records {
                try record.save(database)
            }
            for record in quarantinedRecords {
                try record.save(database)
            }
            for record in recoveryRecords {
                try record.save(database)
            }
        }
    }

    func saveQuarantinedRESTWrites(
        _ writes: [SharedPlanRESTWrite],
        currentPlan: SharedPlan?
    ) async throws {
        guard writes.allSatisfy(\.isQuarantined) else {
            throw SharedPlanError.persistenceFailed
        }
        let records = try writes.map { try restWriteRecord(for: $0) }
        let planRecord = try currentPlan.map { try cacheRecord(for: $0) }
        try await database.write { database in
            if let planRecord { try planRecord.save(database) }
            for record in records {
                try record.save(database)
            }
        }
    }

    func replaceQuarantinedRESTWrites(
        removing writeIDs: Set<UUID>,
        with pendingWrites: [SharedPlanRESTWrite],
        plan: SharedPlan
    ) async throws {
        guard pendingWrites.allSatisfy({ !$0.isQuarantined }) else {
            throw SharedPlanError.persistenceFailed
        }
        let planRecord = try cacheRecord(for: plan)
        let pendingRecords = try pendingWrites.map { try restWriteRecord(for: $0) }
        try await database.write { database in
            for id in writeIDs {
                _ = try SharedPlanRESTWriteRecord.deleteOne(
                    database,
                    key: id.uuidString.lowercased()
                )
            }
            for record in pendingRecords { try record.save(database) }
            try planRecord.save(database)
        }
    }

    func saveAcknowledgedPlan(
        _ plan: SharedPlan,
        removingWriteID: UUID,
        rebasedWrites: [SharedPlanRESTWrite]
    ) async throws {
        let record = try cacheRecord(for: plan)
        let rebasedRecords = try rebasedWrites.map { try restWriteRecord(for: $0) }
        try await database.write { database in
            try record.save(database)
            _ = try SharedPlanRESTWriteRecord.deleteOne(
                database,
                key: removingWriteID.uuidString.lowercased()
            )
            for rebasedRecord in rebasedRecords {
                try rebasedRecord.save(database)
            }
        }
    }

    func removeRESTWrite(id: UUID) async throws {
        try await database.write { database in
            _ = try SharedPlanRESTWriteRecord.deleteOne(
                database,
                key: id.uuidString.lowercased()
            )
        }
    }

    func removePlan(id: String) async throws {
        try await database.write { database in
            _ = try SharedPlanCacheRecord.deleteOne(database, key: id)
            _ = try SharedPlanDocumentRecord.deleteOne(database, key: id)
            _ = try SharedPlanRESTWriteRecord
                .filter(Column("planID") == id)
                .deleteAll(database)
            _ = try SharedPlanMemoDraftRecord
                .filter(Column("planID") == id)
                .deleteAll(database)
        }
    }

    func removeArchivedRecoveryDocument(id: UUID) async throws {
        try await database.write { database in
            _ = try SharedPlanArchivedRecoveryRecord.deleteOne(
                database,
                key: id.uuidString.lowercased()
            )
        }
    }

    func removeAll() async throws {
        try await database.write { database in
            try SharedPlanRESTWriteRecord.deleteAll(database)
            try SharedPlanDocumentRecord.deleteAll(database)
            try SharedPlanCacheRecord.deleteAll(database)
            try SharedPlanMetadataRecord.deleteAll(database)
            try SharedPlanArchivedRecoveryRecord.deleteAll(database)
            try SharedPlanNotificationReadIntentRecord.deleteAll(database)
            try SharedPlanNotificationRecord.deleteAll(database)
            try SharedPlanMemoDraftRecord.deleteAll(database)
        }
    }

    private func cacheRecord(for plan: SharedPlan) throws -> SharedPlanCacheRecord {
        SharedPlanCacheRecord(
            id: plan.id,
            comiketNo: plan.comiketNo,
            lifecycle: plan.lifecycle.rawValue,
            ownership: plan.ownership.rawValue,
            payload: try encoder.encode(plan),
            updatedAt: plan.updatedAt
        )
    }

    private func restWriteRecord(for write: SharedPlanRESTWrite) throws -> SharedPlanRESTWriteRecord {
        SharedPlanRESTWriteRecord(
            id: write.id.uuidString.lowercased(),
            planID: write.planID,
            payload: try encoder.encode(write),
            createdAt: write.createdAt
        )
    }

    private func documentRecord(
        for snapshot: SharedPlanDocumentSnapshot
    ) throws -> SharedPlanDocumentRecord {
        SharedPlanDocumentRecord(
            planID: snapshot.planID,
            replicaID: snapshot.replicaID.uuidString.lowercased(),
            actorID: snapshot.actorID,
            document: snapshot.document,
            pendingOperationIDs: try encoder.encode(snapshot.pendingOperationIDs),
            syncIssue: try snapshot.syncIssue.map { try encoder.encode($0) },
            localEditLimit: try snapshot.localEditLimit.map { try encoder.encode($0) },
            offlineMutationAuthority: snapshot.offlineMutationAuthority,
            updatedAt: Date()
        )
    }

    private func archivedRecoveryRecord(
        for recovery: ArchivedSharedPlanRecovery
    ) throws -> SharedPlanArchivedRecoveryRecord {
        SharedPlanArchivedRecoveryRecord(
            id: recovery.id.uuidString.lowercased(),
            planID: recovery.snapshot.planID,
            replicaID: recovery.snapshot.replicaID.uuidString.lowercased(),
            actorID: recovery.snapshot.actorID,
            document: recovery.snapshot.document,
            pendingOperationIDs: try encoder.encode(recovery.snapshot.pendingOperationIDs),
            syncIssue: try recovery.snapshot.syncIssue.map { try encoder.encode($0) },
            localEditLimit: try recovery.snapshot.localEditLimit.map {
                try encoder.encode($0)
            },
            offlineMutationAuthority: recovery.snapshot.offlineMutationAuthority,
            metadataIntents: try encoder.encode(recovery.metadataIntents),
            updatedAt: Date()
        )
    }

    private func memoDraftRecord(
        for draft: SharedPlanMemoDraft
    ) throws -> SharedPlanMemoDraftRecord {
        guard draft.generation <= UInt64(Int64.max) else {
            throw SharedPlanError.persistenceFailed
        }
        return SharedPlanMemoDraftRecord(
            planID: draft.planID,
            replicaID: draft.replicaID.uuidString.lowercased(),
            comiketNo: draft.circle.comiketNo,
            wcID: draft.circle.wcID,
            generation: Int64(draft.generation),
            payload: try encoder.encode(draft),
            updatedAt: draft.updatedAt
        )
    }
}

actor InMemorySharedPlanPersistence: SharedPlanPersisting {
    private let storedReplicaID: UUID
    private var plans: [String: SharedPlan] = [:]
    private var writes: [UUID: SharedPlanRESTWrite] = [:]
    private var documents: [String: SharedPlanDocumentSnapshot] = [:]
    private var archivedRecoveries: [UUID: ArchivedSharedPlanRecovery] = [:]
    private var notifications: [String: SharedPlanNotificationItem] = [:]
    private var notificationReadIntents: [String: Date] = [:]
    private var memoDrafts: [String: SharedPlanMemoDraft] = [:]

    init(replicaID: UUID = UUID()) {
        storedReplicaID = replicaID
    }

    func replicaID() async throws -> UUID { storedReplicaID }

    func loadPlans() async throws -> [SharedPlan] {
        plans.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadRESTWrites() async throws -> [SharedPlanRESTWrite] {
        writes.values.sorted { $0.createdAt < $1.createdAt }
    }

    func loadDocument(planID: String) async throws -> SharedPlanDocumentSnapshot? {
        documents[planID]
    }

    func loadOrphanedDocuments(
        excludingPlanIDs: Set<String>
    ) async throws -> [SharedPlanDocumentSnapshot] {
        documents.values.filter { !excludingPlanIDs.contains($0.planID) }
    }

    func loadArchivedRecoveryDocuments() async throws -> [ArchivedSharedPlanRecovery] {
        archivedRecoveries.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func loadNotifications() async throws -> [SharedPlanNotificationItem] {
        notifications.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    func loadNotificationReadIntents() async throws -> [String] {
        notificationReadIntents.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key < $1.key
        }.map(\.key)
    }

    func loadMemoDrafts(planID: String) async throws -> [SharedPlanMemoDraft] {
        memoDrafts.values
            .filter { $0.planID == planID }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    func savePlan(_ plan: SharedPlan, write: SharedPlanRESTWrite?) async throws {
        plans[plan.id] = plan
        if let write { writes[write.id] = write }
    }

    func saveRESTWrite(_ write: SharedPlanRESTWrite) async throws {
        writes[write.id] = write
    }

    func saveNotifications(_ notifications: [SharedPlanNotificationItem]) async throws {
        for incoming in notifications {
            var notification = incoming
            if notification.readAt == nil {
                notification.readAt = self.notifications[notification.id]?.readAt
            }
            self.notifications[notification.id] = notification
        }
    }

    func saveNotificationReadIntent(eventID: String, createdAt: Date) async throws {
        notificationReadIntents[eventID] = createdAt
    }

    func acknowledgeNotificationRead(
        _ receipt: SharedPlanNotificationReadReceipt
    ) async throws {
        guard var notification = notifications[receipt.id] else {
            throw SharedPlanError.persistenceFailed
        }
        notification.readAt = notification.readAt ?? receipt.readAt
        notifications[receipt.id] = notification
        notificationReadIntents[receipt.id] = nil
    }

    func removeNotificationReadIntent(eventID: String) async throws {
        notificationReadIntents[eventID] = nil
    }

    func saveBootstrappedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        removingWriteID: UUID?
    ) async throws {
        guard plan.id == document.planID else {
            throw SharedPlanError.persistenceFailed
        }
        plans[plan.id] = plan
        documents[document.planID] = document
        if let removingWriteID { writes[removingWriteID] = nil }
    }

    func saveDiscardedContentRebootstrap(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        discardingMemoDraftReplicaID: UUID
    ) async throws {
        guard plan.id == document.planID,
              document.replicaID == discardingMemoDraftReplicaID
        else { throw SharedPlanError.persistenceFailed }
        plans[plan.id] = plan
        documents[document.planID] = document
        memoDrafts = memoDrafts.filter {
            $0.value.planID != plan.id
                || $0.value.replicaID != discardingMemoDraftReplicaID
        }
    }

    func saveMutation(plan: SharedPlan, document: SharedPlanDocumentSnapshot) async throws {
        guard plan.id == document.planID else { throw SharedPlanError.persistenceFailed }
        plans[plan.id] = plan
        documents[plan.id] = document
    }

    func saveMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        let key = Self.memoDraftKey(draft)
        guard memoDrafts[key]?.generation ?? 0 <= draft.generation else { return }
        memoDrafts[key] = draft
    }

    func saveMemoMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        acknowledging draft: SharedPlanMemoDraft
    ) async throws {
        guard plan.id == document.planID,
              draft.planID == plan.id,
              draft.replicaID == document.replicaID
        else { throw SharedPlanError.persistenceFailed }
        plans[plan.id] = plan
        documents[plan.id] = document
        let key = Self.memoDraftKey(draft)
        if memoDrafts[key]?.generation == draft.generation {
            memoDrafts[key] = nil
        }
    }

    func saveRecoveryDocument(_ document: SharedPlanDocumentSnapshot) async throws {
        documents[document.planID] = document
    }

    func replaceReinstatedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        retaining recovery: ArchivedSharedPlanRecovery
    ) async throws {
        guard plan.id == document.planID,
              recovery.snapshot.planID == plan.id,
              recovery.snapshot.replicaID != document.replicaID,
              recovery.metadataIntents.allSatisfy({
                  $0.planID == plan.id && $0.quarantineReason == .membershipRevoked
              })
        else { throw SharedPlanError.persistenceFailed }
        archivedRecoveries[recovery.id] = recovery
        for intent in recovery.metadataIntents { writes[intent.id] = nil }
        plans[plan.id] = plan
        documents[plan.id] = document
    }

    func reconcileCachedPlans(
        _ plans: [SharedPlan],
        quarantinedWrites: [SharedPlanRESTWrite],
        recoveryDocuments: [SharedPlanDocumentSnapshot]
    ) async throws {
        self.plans = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        for write in quarantinedWrites { writes[write.id] = write }
        for document in recoveryDocuments { documents[document.planID] = document }
    }

    func saveQuarantinedRESTWrites(
        _ writes: [SharedPlanRESTWrite],
        currentPlan: SharedPlan?
    ) async throws {
        guard writes.allSatisfy(\.isQuarantined) else {
            throw SharedPlanError.persistenceFailed
        }
        if let currentPlan { plans[currentPlan.id] = currentPlan }
        for write in writes { self.writes[write.id] = write }
    }

    func replaceQuarantinedRESTWrites(
        removing writeIDs: Set<UUID>,
        with pendingWrites: [SharedPlanRESTWrite],
        plan: SharedPlan
    ) async throws {
        guard pendingWrites.allSatisfy({ !$0.isQuarantined }) else {
            throw SharedPlanError.persistenceFailed
        }
        for id in writeIDs { writes[id] = nil }
        for write in pendingWrites { writes[write.id] = write }
        plans[plan.id] = plan
    }

    func saveAcknowledgedPlan(
        _ plan: SharedPlan,
        removingWriteID: UUID,
        rebasedWrites: [SharedPlanRESTWrite]
    ) async throws {
        plans[plan.id] = plan
        writes[removingWriteID] = nil
        for write in rebasedWrites { writes[write.id] = write }
    }

    func removeRESTWrite(id: UUID) async throws {
        writes[id] = nil
    }

    func removePlan(id: String) async throws {
        plans[id] = nil
        documents[id] = nil
        writes = writes.filter { $0.value.planID != id }
        memoDrafts = memoDrafts.filter { $0.value.planID != id }
    }

    func removeArchivedRecoveryDocument(id: UUID) async throws {
        archivedRecoveries[id] = nil
    }

    func removeAll() async throws {
        plans.removeAll()
        writes.removeAll()
        documents.removeAll()
        archivedRecoveries.removeAll()
        notifications.removeAll()
        notificationReadIntents.removeAll()
        memoDrafts.removeAll()
    }

    private static func memoDraftKey(_ draft: SharedPlanMemoDraft) -> String {
        "\(draft.planID):\(draft.replicaID.uuidString.lowercased()):\(draft.circle.id)"
    }
}

/// Fail-closed production fallback used only when durable SQLite storage
/// cannot be opened or migrated. Every operation rejects; it never reports an
/// in-memory write as safely persisted.
struct UnavailableSharedPlanPersistence: SharedPlanPersisting {
    func replicaID() async throws -> UUID { throw SharedPlanError.persistenceFailed }
    func loadPlans() async throws -> [SharedPlan] { throw SharedPlanError.persistenceFailed }
    func loadRESTWrites() async throws -> [SharedPlanRESTWrite] {
        throw SharedPlanError.persistenceFailed
    }
    func loadDocument(planID: String) async throws -> SharedPlanDocumentSnapshot? {
        throw SharedPlanError.persistenceFailed
    }
    func loadOrphanedDocuments(
        excludingPlanIDs: Set<String>
    ) async throws -> [SharedPlanDocumentSnapshot] {
        throw SharedPlanError.persistenceFailed
    }
    func loadArchivedRecoveryDocuments() async throws -> [ArchivedSharedPlanRecovery] {
        throw SharedPlanError.persistenceFailed
    }
    func loadNotifications() async throws -> [SharedPlanNotificationItem] {
        throw SharedPlanError.persistenceFailed
    }
    func loadNotificationReadIntents() async throws -> [String] {
        throw SharedPlanError.persistenceFailed
    }
    func loadMemoDrafts(planID: String) async throws -> [SharedPlanMemoDraft] {
        throw SharedPlanError.persistenceFailed
    }
    func saveRESTWrite(_ write: SharedPlanRESTWrite) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveNotifications(_ notifications: [SharedPlanNotificationItem]) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveNotificationReadIntent(eventID: String, createdAt: Date) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func acknowledgeNotificationRead(
        _ receipt: SharedPlanNotificationReadReceipt
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func removeNotificationReadIntent(eventID: String) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveBootstrappedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        removingWriteID: UUID?
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveDiscardedContentRebootstrap(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        discardingMemoDraftReplicaID: UUID
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func savePlan(_ plan: SharedPlan, write: SharedPlanRESTWrite?) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveMemoDraft(_ draft: SharedPlanMemoDraft) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveMemoMutation(
        plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        acknowledging draft: SharedPlanMemoDraft
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveRecoveryDocument(_ document: SharedPlanDocumentSnapshot) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func replaceReinstatedPlan(
        _ plan: SharedPlan,
        document: SharedPlanDocumentSnapshot,
        retaining recovery: ArchivedSharedPlanRecovery
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func reconcileCachedPlans(
        _ plans: [SharedPlan],
        quarantinedWrites: [SharedPlanRESTWrite],
        recoveryDocuments: [SharedPlanDocumentSnapshot]
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveQuarantinedRESTWrites(
        _ writes: [SharedPlanRESTWrite],
        currentPlan: SharedPlan?
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func replaceQuarantinedRESTWrites(
        removing writeIDs: Set<UUID>,
        with pendingWrites: [SharedPlanRESTWrite],
        plan: SharedPlan
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func saveAcknowledgedPlan(
        _ plan: SharedPlan,
        removingWriteID: UUID,
        rebasedWrites: [SharedPlanRESTWrite]
    ) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func removeRESTWrite(id: UUID) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func removePlan(id: String) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func removeArchivedRecoveryDocument(id: UUID) async throws {
        throw SharedPlanError.persistenceFailed
    }
    func removeAll() async throws {
        throw SharedPlanError.persistenceFailed
    }
}

private struct SharedPlanCacheRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanCache"

    let id: String
    let comiketNo: Int
    let lifecycle: String
    let ownership: String
    let payload: Data
    let updatedAt: Date
}

private struct SharedPlanDocumentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanDocument"

    let planID: String
    let replicaID: String
    let actorID: String
    let document: Data
    let pendingOperationIDs: Data
    let syncIssue: Data?
    let localEditLimit: Data?
    let offlineMutationAuthority: Bool
    let updatedAt: Date
}

private struct SharedPlanArchivedRecoveryRecord: Codable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "sharedPlanArchivedRecovery"

    let id: String
    let planID: String
    let replicaID: String
    let actorID: String
    let document: Data
    let pendingOperationIDs: Data
    let syncIssue: Data?
    let localEditLimit: Data?
    let offlineMutationAuthority: Bool
    let metadataIntents: Data?
    let updatedAt: Date
}

private struct SharedPlanRESTWriteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanRESTWrite"

    let id: String
    let planID: String
    let payload: Data
    let createdAt: Date
}

private struct SharedPlanMetadataRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanMetadata"

    let key: String
    let value: String
}

private struct SharedPlanNotificationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanNotification"

    let id: String
    let payload: Data
    let createdAt: Date
}

private struct SharedPlanNotificationReadIntentRecord: Codable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "sharedPlanNotificationReadIntent"

    let eventID: String
    let createdAt: Date
}

private struct SharedPlanMemoDraftRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sharedPlanMemoDraft"

    let planID: String
    let replicaID: String
    let comiketNo: Int
    let wcID: Int
    let generation: Int64
    let payload: Data
    let updatedAt: Date
}
