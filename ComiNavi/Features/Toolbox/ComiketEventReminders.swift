import Foundation
import Observation
import UIKit
import UserNotifications

enum ComiketReminderKind: String, CaseIterable, Identifiable, Sendable {
    case earlyEntry = "early-entry"
    case amEntry = "am-entry"
    case pmEntry = "pm-entry"
    case circleClose = "circle-close"

    var id: String { rawValue }

    var eventHour: Int {
        switch self {
        case .earlyEntry: 10
        case .amEntry: 11
        case .pmEntry: 12
        case .circleClose: 16
        }
    }

    var eventMinute: Int {
        switch self {
        case .earlyEntry, .pmEntry: 30
        case .amEntry, .circleClose: 0
        }
    }

    var timeLabel: String {
        String(format: "%02d:%02d", eventHour, eventMinute)
    }

    var title: LocalizedStringResource {
        switch self {
        case .earlyEntry: "Early Entry"
        case .amEntry: "AM Entry"
        case .pmEntry: "PM Entry"
        case .circleClose: "Circle spaces close"
        }
    }

    var notificationTitle: String {
        switch self {
        case .earlyEntry: String(localized: "Early Entry starts in 15 minutes")
        case .amEntry: String(localized: "AM Entry starts in 15 minutes")
        case .pmEntry: String(localized: "PM Entry starts in 15 minutes")
        case .circleClose: String(localized: "Circle spaces close in 15 minutes")
        }
    }

    var notificationDetail: String {
        switch self {
        case .earlyEntry:
            String(localized: "Keep your ticket, wristband, and photo ID ready.")
        case .amEntry:
            String(localized: "The AM entry queue starts moving soon.")
        case .pmEntry:
            String(localized: "PM entry begins soon. Follow current staff guidance.")
        case .circleClose:
            String(localized: "Finish purchases and check your remaining plan.")
        }
    }
}

struct ComiketReminderRequest: Equatable, Sendable {
    let identifier: String
    let eventNumber: Int
    let day: Int
    let kind: ComiketReminderKind
    let fireDate: Date
    let title: String
    let body: String
}

enum ComiketEventReminderCatalog {
    static let eventNumber = 108
    static let leadTime: TimeInterval = 15 * 60
    static let officialScheduleURL = URL(
        string: "https://www.comiket.co.jp/info-a/TAFO/C108TAFO/ticket.html"
    )!

    private static let eventDays = [
        (day: 1, year: 2026, month: 8, date: 15),
        (day: 2, year: 2026, month: 8, date: 16),
    ]

    static var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func requests(
        for enabledKinds: Set<ComiketReminderKind>,
        now: Date = Date()
    ) -> [ComiketReminderRequest] {
        eventDays.flatMap { eventDay in
            enabledKinds.compactMap { kind in
                let components = DateComponents(
                    timeZone: tokyoCalendar.timeZone,
                    year: eventDay.year,
                    month: eventDay.month,
                    day: eventDay.date,
                    hour: kind.eventHour,
                    minute: kind.eventMinute
                )
                guard let eventDate = tokyoCalendar.date(from: components) else { return nil }

                let fireDate = eventDate.addingTimeInterval(-leadTime)
                guard fireDate > now else { return nil }

                let dayLabel = String.localizedStringWithFormat(
                    String(localized: "C108 Day %lld"),
                    eventDay.day
                )
                return ComiketReminderRequest(
                    identifier: requestIdentifier(day: eventDay.day, kind: kind),
                    eventNumber: eventNumber,
                    day: eventDay.day,
                    kind: kind,
                    fireDate: fireDate,
                    title: kind.notificationTitle,
                    body: "\(dayLabel) · \(kind.timeLabel) · \(kind.notificationDetail)"
                )
            }
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    static func requestIdentifier(day: Int, kind: ComiketReminderKind) -> String {
        "\(SystemComiketNotificationScheduler.requestPrefix).c108.day\(day).\(kind.rawValue)"
    }
}

enum ComiketNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized(timeSensitiveEnabled: Bool)
}

protocol ComiketNotificationScheduling: Sendable {
    func authorization() async -> ComiketNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func replaceOwnedRequests(with requests: [ComiketReminderRequest]) async throws
}

struct SystemComiketNotificationScheduler: ComiketNotificationScheduling {
    static let requestPrefix = "cominavi.event-reminder"

    func authorization() async -> ComiketNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized(timeSensitiveEnabled: settings.timeSensitiveSetting == .enabled)
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        // Time Sensitive delivery is granted by the target capability and remains under the
        // person's control in Settings. UNAuthorizationOptions.timeSensitive is deprecated.
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return granted
    }

    func replaceOwnedRequests(with requests: [ComiketReminderRequest]) async throws {
        let center = UNUserNotificationCenter.current()
        let ownedIdentifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ownedIdentifiers)

        for reminder in requests {
            try await center.add(Self.notificationRequest(for: reminder))
        }
    }

    static func notificationRequest(for reminder: ComiketReminderRequest) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "cominavi-c108-timetable"
        content.userInfo = [
            "event": reminder.eventNumber,
            "day": reminder.day,
            "kind": reminder.kind.rawValue,
        ]

        let calendar = ComiketEventReminderCatalog.tokyoCalendar
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.fireDate
        )
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        return UNNotificationRequest(
            identifier: reminder.identifier,
            content: content,
            trigger: trigger
        )
    }
}

@MainActor
@Observable
final class ComiketReminderStore {
    enum State: Equatable {
        case checking
        case notDetermined
        case denied
        case authorized(timeSensitiveEnabled: Bool)
    }

    private(set) var state: State = .checking
    private(set) var errorMessage: String?
    private(set) var enabledKinds: Set<ComiketReminderKind>

    @ObservationIgnored private let scheduler: any ComiketNotificationScheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var updateRevision = 0

    private static let enabledKindsKey = "comiket.event-reminders.c108.enabled-kinds.v1"

    init(
        scheduler: any ComiketNotificationScheduling = SystemComiketNotificationScheduler(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        let persisted = Set(defaults.stringArray(forKey: Self.enabledKindsKey) ?? [])
        enabledKinds = Set(ComiketReminderKind.allCases.filter { persisted.contains($0.rawValue) })
    }

    func isEnabled(_ kind: ComiketReminderKind) -> Bool {
        enabledKinds.contains(kind)
    }

    func refresh() async {
        state = state(for: await scheduler.authorization())
        guard case .authorized = state else { return }
        await reconcile()
    }

    func setEnabled(_ enabled: Bool, for kind: ComiketReminderKind) async {
        let mutation = applyOptimisticSelection(enabled, for: kind)
        await finishSelection(mutation)
    }

    func setEnabledOptimistically(_ enabled: Bool, for kind: ComiketReminderKind) {
        let mutation = applyOptimisticSelection(enabled, for: kind)
        Task { [weak self] in
            await self?.finishSelection(mutation)
        }
    }

    private func applyOptimisticSelection(
        _ enabled: Bool,
        for kind: ComiketReminderKind
    ) -> ReminderSelectionMutation {
        updateRevision += 1
        errorMessage = nil
        let previousEnabledKinds = enabledKinds
        if enabled {
            enabledKinds.insert(kind)
        } else {
            enabledKinds.remove(kind)
        }
        persistSelection()
        return ReminderSelectionMutation(
            revision: updateRevision,
            enabled: enabled,
            kind: kind,
            previousEnabledKinds: previousEnabledKinds
        )
    }

    private func finishSelection(_ mutation: ReminderSelectionMutation) async {
        do {
            var authorization = await scheduler.authorization()
            if mutation.enabled, authorization == .notDetermined {
                _ = try await scheduler.requestAuthorization()
                authorization = await scheduler.authorization()
            }
            guard mutation.revision == updateRevision else { return }
            state = state(for: authorization)

            if mutation.enabled, case .authorized = authorization {
                // The optimistic selection is already applied.
            } else if mutation.enabled {
                enabledKinds.remove(mutation.kind)
                persistSelection()
                return
            }
            try await scheduleSelection()
        } catch {
            guard mutation.revision == updateRevision else { return }
            enabledKinds = mutation.previousEnabledKinds
            persistSelection()
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func reconcile() async {
        do {
            try await scheduleSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSelection() async throws {
        while true {
            let scheduledRevision = updateRevision
            let requests = ComiketEventReminderCatalog.requests(for: enabledKinds, now: now())
            try await scheduler.replaceOwnedRequests(with: requests)
            guard scheduledRevision != updateRevision else { return }
        }
    }

    private func persistSelection() {
        defaults.set(enabledKinds.map(\.rawValue).sorted(), forKey: Self.enabledKindsKey)
    }

    private func state(for authorization: ComiketNotificationAuthorization) -> State {
        switch authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized(let timeSensitiveEnabled):
            .authorized(timeSensitiveEnabled: timeSensitiveEnabled)
        }
    }
}

private struct ReminderSelectionMutation: Sendable {
    let revision: Int
    let enabled: Bool
    let kind: ComiketReminderKind
    let previousEnabledKinds: Set<ComiketReminderKind>
}
