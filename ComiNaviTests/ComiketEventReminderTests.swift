import Foundation
import UserNotifications
import XCTest

@testable import ComiNavi

@MainActor
final class ComiketEventReminderTests: XCTestCase {
    func testC108PlanCreatesTwoTimeSensitiveCandidatesPerMilestone() throws {
        let now = try date("2026-08-09T00:00:00Z")
        let requests = ComiketEventReminderCatalog.requests(
            for: Set(ComiketReminderKind.allCases),
            now: now
        )

        XCTAssertEqual(requests.count, 8)
        XCTAssertEqual(
            requests.first?.identifier,
            "cominavi.event-reminder.c108.day1.early-entry.15m"
        )
        XCTAssertEqual(requests.first?.fireDate, try date("2026-08-15T01:15:00Z"))
        XCTAssertEqual(requests.first?.kind, .earlyEntry)
        XCTAssertEqual(requests.first?.day, 1)
        XCTAssertEqual(
            requests.last?.identifier,
            "cominavi.event-reminder.c108.day2.circle-close.120m"
        )
        XCTAssertEqual(requests.last?.fireDate, try date("2026-08-16T05:00:00Z"))
    }

    func testCircleCloseDefaultsToFourteenHundredOnBothDays() throws {
        let requests = ComiketEventReminderCatalog.requests(
            for: [.circleClose],
            now: try date("2026-08-09T00:00:00Z")
        )

        XCTAssertEqual(requests.map(\.timing), [.twoHoursBefore, .twoHoursBefore])
        XCTAssertEqual(requests.map(\.fireDate), [
            try date("2026-08-15T05:00:00Z"),
            try date("2026-08-16T05:00:00Z"),
        ])
        XCTAssertTrue(requests.allSatisfy { $0.identifier.hasSuffix(".120m") })
    }

    func testPlanSupportsAtEventAndIndependentAdvanceTimings() throws {
        let requests = ComiketEventReminderCatalog.requests(
            for: [.earlyEntry, .pmEntry],
            timings: [
                .earlyEntry: .atEvent,
                .pmEntry: .thirtyMinutesBefore,
            ],
            now: try date("2026-08-09T00:00:00Z")
        )

        let dayOneEarlyEntry = try XCTUnwrap(
            requests.first { $0.day == 1 && $0.kind == .earlyEntry }
        )
        XCTAssertEqual(dayOneEarlyEntry.timing, .atEvent)
        XCTAssertEqual(dayOneEarlyEntry.fireDate, try date("2026-08-15T01:30:00Z"))
        XCTAssertEqual(
            dayOneEarlyEntry.identifier,
            "cominavi.event-reminder.c108.day1.early-entry.0m"
        )
        XCTAssertTrue(dayOneEarlyEntry.body.hasPrefix("Now ·"))

        let dayOnePMEntry = try XCTUnwrap(
            requests.first { $0.day == 1 && $0.kind == .pmEntry }
        )
        XCTAssertEqual(dayOnePMEntry.timing, .thirtyMinutesBefore)
        XCTAssertEqual(dayOnePMEntry.fireDate, try date("2026-08-15T03:00:00Z"))
        XCTAssertEqual(
            dayOnePMEntry.identifier,
            "cominavi.event-reminder.c108.day1.pm-entry.30m"
        )
        XCTAssertTrue(dayOnePMEntry.body.hasPrefix("In 30 minutes ·"))
    }

    func testPlanNeverSchedulesMilestonesThatAlreadyPassed() throws {
        let afterDayTwoAMEntryReminder = try date("2026-08-16T02:00:00Z")
        let requests = ComiketEventReminderCatalog.requests(
            for: Set(ComiketReminderKind.allCases),
            now: afterDayTwoAMEntryReminder
        )

        XCTAssertEqual(requests.map(\.kind), [.pmEntry, .circleClose])
        XCTAssertTrue(requests.allSatisfy { $0.day == 2 })
    }

    func testSystemRequestUsesTimeSensitiveContentAndTokyoCalendarTrigger() throws {
        let reminder = try XCTUnwrap(
            ComiketEventReminderCatalog.requests(
                for: [.earlyEntry],
                now: date("2026-08-09T00:00:00Z")
            ).first
        )

        let request = SystemComiketNotificationScheduler.notificationRequest(for: reminder)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)

        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(request.content.sound, .default)
        XCTAssertEqual(trigger.dateComponents.timeZone?.identifier, "Asia/Tokyo")
        XCTAssertEqual(trigger.dateComponents.hour, 10)
        XCTAssertEqual(trigger.dateComponents.minute, 15)
        XCTAssertFalse(trigger.repeats)
    }

    func testFirstToggleRequestsPermissionSchedulesBothDaysAndPersists() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(authorization: .notDetermined)
        let now = try date("2026-08-09T00:00:00Z")
        let store = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )

        await store.setEnabled(true, for: .earlyEntry)

        let authorizationRequestCount = await scheduler.authorizationRequestCount()
        let scheduled = await scheduler.latestRequests()
        XCTAssertTrue(store.isEnabled(.earlyEntry))
        XCTAssertEqual(store.state, .authorized(timeSensitiveEnabled: true))
        XCTAssertEqual(authorizationRequestCount, 1)
        XCTAssertEqual(scheduled.count, 2)
        XCTAssertEqual(scheduled.map(\.day), [1, 2])

        let reopened = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )
        XCTAssertTrue(reopened.isEnabled(.earlyEntry))
    }

    func testLegacyEnabledKindsMigrateWithoutCreatingExplicitTimingOverrides() throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ComiketReminderKind.earlyEntry.rawValue, ComiketReminderKind.circleClose.rawValue],
            forKey: "comiket.event-reminders.c108.enabled-kinds.v1"
        )

        let store = ComiketReminderStore(
            scheduler: ReminderSchedulerSpy(authorization: .denied),
            defaults: defaults
        )

        XCTAssertTrue(store.isEnabled(.earlyEntry))
        XCTAssertTrue(store.isEnabled(.circleClose))
        XCTAssertEqual(store.timing(for: .earlyEntry), .fifteenMinutesBefore)
        XCTAssertEqual(store.timing(for: .circleClose), .twoHoursBefore)
        XCTAssertTrue(store.selectedTimings.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "comiket.event-reminders.c108.settings.v2"))
    }

    func testExplicitCircleCloseTimingSurvivesRelaunchAndRescheduling() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ComiketReminderKind.circleClose.rawValue],
            forKey: "comiket.event-reminders.c108.enabled-kinds.v1"
        )
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true)
        )
        let now = try date("2026-08-09T00:00:00Z")
        let store = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )

        await store.setTiming(.atEvent, for: .circleClose)

        let reopened = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )
        await reopened.refresh()

        XCTAssertEqual(reopened.timing(for: .circleClose), .atEvent)
        let requests = await scheduler.latestRequests()
        XCTAssertEqual(requests.map(\.fireDate), [
            try date("2026-08-15T07:00:00Z"),
            try date("2026-08-16T07:00:00Z"),
        ])
        XCTAssertTrue(requests.allSatisfy { $0.identifier.hasSuffix(".0m") })
    }

    func testTimingChoicePersistsWhileReminderIsDisabled() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(authorization: .denied)
        let store = ComiketReminderStore(scheduler: scheduler, defaults: defaults)

        await store.setTiming(.oneHourBefore, for: .amEntry)

        XCTAssertEqual(store.timing(for: .amEntry), .oneHourBefore)
        let reopened = ComiketReminderStore(scheduler: scheduler, defaults: defaults)
        XCTAssertEqual(reopened.timing(for: .amEntry), .oneHourBefore)
    }

    func testTimingChangeReplacesRequestsWithTimingSpecificIdentifiers() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true)
        )
        let now = try date("2026-08-09T00:00:00Z")
        let store = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )

        await store.setEnabled(true, for: .earlyEntry)
        await store.setTiming(.atEvent, for: .earlyEntry)

        let replacements = await scheduler.replacementHistory()
        XCTAssertEqual(replacements.count, 2)
        XCTAssertTrue(replacements[0].allSatisfy { $0.identifier.hasSuffix(".15m") })
        XCTAssertTrue(replacements[1].allSatisfy { $0.identifier.hasSuffix(".0m") })
        XCTAssertEqual(replacements[1].map(\.fireDate), [
            try date("2026-08-15T01:30:00Z"),
            try date("2026-08-16T01:30:00Z"),
        ])
    }

    func testRefreshReschedulesMilestonesAfterClockRollback() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = TestClock(now: try date("2026-08-15T02:00:00Z"))
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true)
        )
        let store = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults,
            now: { clock.current() }
        )

        await store.setEnabled(true, for: .earlyEntry)
        let requestsBeforeRollback = await scheduler.latestRequests()
        XCTAssertEqual(requestsBeforeRollback.map(\.day), [2])

        clock.set(try date("2026-08-14T00:00:00Z"))
        await store.refresh()

        let requestsAfterRollback = await scheduler.latestRequests()
        XCTAssertEqual(requestsAfterRollback.map(\.day), [1, 2])
    }

    func testDeniedPermissionDoesNotEnableReminder() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(authorization: .denied)
        let store = ComiketReminderStore(scheduler: scheduler, defaults: defaults)

        await store.setEnabled(true, for: .pmEntry)

        let scheduled = await scheduler.latestRequests()
        XCTAssertFalse(store.isEnabled(.pmEntry))
        XCTAssertEqual(store.state, .denied)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testToggleUpdatesImmediatelyBeforeSchedulingCompletes() throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true)
        )
        let store = ComiketReminderStore(scheduler: scheduler, defaults: defaults)

        store.setEnabledOptimistically(true, for: .pmEntry)

        XCTAssertTrue(store.isEnabled(.pmEntry))
    }

    func testSchedulingFailureRollsBackOptimisticSelection() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true),
            replacementError: ReminderSchedulerTestError.replacementFailed
        )
        let store = ComiketReminderStore(scheduler: scheduler, defaults: defaults)

        await store.setEnabled(true, for: .circleClose)

        XCTAssertFalse(store.isEnabled(.circleClose))
        XCTAssertNotNil(store.errorMessage)

        let reopened = ComiketReminderStore(
            scheduler: scheduler,
            defaults: defaults
        )
        XCTAssertFalse(reopened.isEnabled(.circleClose))
    }

    func testSchedulingFailureRollsBackOptimisticTiming() async throws {
        let suiteName = "ComiketEventReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ComiketReminderKind.circleClose.rawValue],
            forKey: "comiket.event-reminders.c108.enabled-kinds.v1"
        )
        let scheduler = ReminderSchedulerSpy(
            authorization: .authorized(timeSensitiveEnabled: true),
            replacementError: ReminderSchedulerTestError.replacementFailed
        )
        let store = ComiketReminderStore(scheduler: scheduler, defaults: defaults)

        await store.setTiming(.atEvent, for: .circleClose)

        XCTAssertEqual(store.timing(for: .circleClose), .twoHoursBefore)
        XCTAssertNotNil(store.errorMessage)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private actor ReminderSchedulerSpy: ComiketNotificationScheduling {
    private var currentAuthorization: ComiketNotificationAuthorization
    private let replacementError: ReminderSchedulerTestError?
    private var requestCount = 0
    private var replacements: [[ComiketReminderRequest]] = []

    init(
        authorization: ComiketNotificationAuthorization,
        replacementError: ReminderSchedulerTestError? = nil
    ) {
        currentAuthorization = authorization
        self.replacementError = replacementError
    }

    func authorization() async -> ComiketNotificationAuthorization {
        currentAuthorization
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        currentAuthorization = .authorized(timeSensitiveEnabled: true)
        return true
    }

    func replaceOwnedRequests(with requests: [ComiketReminderRequest]) async throws {
        if let replacementError { throw replacementError }
        replacements.append(requests)
    }

    func authorizationRequestCount() -> Int {
        requestCount
    }

    func latestRequests() -> [ComiketReminderRequest] {
        replacements.last ?? []
    }

    func replacementHistory() -> [[ComiketReminderRequest]] {
        replacements
    }
}

private enum ReminderSchedulerTestError: Error {
    case replacementFailed
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(now: Date) {
        self.now = now
    }

    func current() -> Date {
        lock.withLock { now }
    }

    func set(_ date: Date) {
        lock.withLock { now = date }
    }
}
