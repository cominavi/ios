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
        XCTAssertEqual(requests.first?.identifier, "cominavi.event-reminder.c108.day1.early-entry")
        XCTAssertEqual(requests.first?.fireDate, try date("2026-08-15T01:15:00Z"))
        XCTAssertEqual(requests.first?.kind, .earlyEntry)
        XCTAssertEqual(requests.first?.day, 1)
        XCTAssertEqual(requests.last?.identifier, "cominavi.event-reminder.c108.day2.circle-close")
        XCTAssertEqual(requests.last?.fireDate, try date("2026-08-16T06:45:00Z"))
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

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private actor ReminderSchedulerSpy: ComiketNotificationScheduling {
    private var currentAuthorization: ComiketNotificationAuthorization
    private var requestCount = 0
    private var replacements: [[ComiketReminderRequest]] = []

    init(authorization: ComiketNotificationAuthorization) {
        currentAuthorization = authorization
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
        replacements.append(requests)
    }

    func authorizationRequestCount() -> Int {
        requestCount
    }

    func latestRequests() -> [ComiketReminderRequest] {
        replacements.last ?? []
    }
}
