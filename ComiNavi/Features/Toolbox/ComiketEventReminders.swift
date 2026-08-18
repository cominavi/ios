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

    var defaultTiming: ComiketReminderTiming {
        .fifteenMinutesBefore
    }

    func notificationTimeLabel(for timing: ComiketReminderTiming) -> String {
        let eventMinutes = eventHour * 60 + eventMinute
        let notificationMinutes = eventMinutes - timing.rawValue
        return String(
            format: "%02d:%02d",
            notificationMinutes / 60,
            notificationMinutes % 60
        )
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

enum ComiketReminderTiming: Int, CaseIterable, Codable, Identifiable, Sendable {
    case atEvent = 0
    case fifteenMinutesBefore = 15
    case thirtyMinutesBefore = 30
    case oneHourBefore = 60
    case twoHoursBefore = 120

    var id: Int { rawValue }
    var leadTime: TimeInterval { TimeInterval(rawValue * 60) }

    var pickerLabel: LocalizedStringResource {
        switch self {
        case .atEvent: "At event time"
        case .fifteenMinutesBefore: "15 minutes before"
        case .thirtyMinutesBefore: "30 minutes before"
        case .oneHourBefore: "1 hour before"
        case .twoHoursBefore: "2 hours before"
        }
    }

    var notificationLeadLabel: String {
        switch self {
        case .atEvent: String(localized: "Now")
        case .fifteenMinutesBefore: String(localized: "In 15 minutes")
        case .thirtyMinutesBefore: String(localized: "In 30 minutes")
        case .oneHourBefore: String(localized: "In 1 hour")
        case .twoHoursBefore: String(localized: "In 2 hours")
        }
    }
}

struct ComiketReminderRequest: Equatable, Sendable {
    let identifier: String
    let eventNumber: Int
    let day: Int
    let kind: ComiketReminderKind
    let timing: ComiketReminderTiming
    let fireDate: Date
    let title: String
    let body: String
}

enum ComiketEventReminderCatalog {
    static let eventNumber = 108
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
        timings: [ComiketReminderKind: ComiketReminderTiming] = [:],
        now: Date = Date()
    ) -> [ComiketReminderRequest] {
        eventDays.flatMap { eventDay in
            enabledKinds.compactMap { kind in
                let timing = timings[kind] ?? kind.defaultTiming
                let components = DateComponents(
                    timeZone: tokyoCalendar.timeZone,
                    year: eventDay.year,
                    month: eventDay.month,
                    day: eventDay.date,
                    hour: kind.eventHour,
                    minute: kind.eventMinute
                )
                guard let eventDate = tokyoCalendar.date(from: components) else { return nil }

                let fireDate = eventDate.addingTimeInterval(-timing.leadTime)
                guard fireDate > now else { return nil }

                let dayLabel = String.localizedStringWithFormat(
                    String(localized: "C108 Day %lld"),
                    eventDay.day
                )
                return ComiketReminderRequest(
                    identifier: requestIdentifier(
                        day: eventDay.day,
                        kind: kind,
                        timing: timing
                    ),
                    eventNumber: eventNumber,
                    day: eventDay.day,
                    kind: kind,
                    timing: timing,
                    fireDate: fireDate,
                    title: String(localized: kind.title),
                    body: "\(timing.notificationLeadLabel) · \(dayLabel) · \(kind.timeLabel) · \(kind.notificationDetail)"
                )
            }
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    static func requestIdentifier(
        day: Int,
        kind: ComiketReminderKind,
        timing: ComiketReminderTiming
    ) -> String {
        "\(SystemComiketNotificationScheduler.requestPrefix).c108.day\(day).\(kind.rawValue).\(timing.rawValue)m"
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
            "lead_minutes": reminder.timing.rawValue,
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
    private(set) var selectedTimings: [ComiketReminderKind: ComiketReminderTiming]

    @ObservationIgnored private let scheduler: any ComiketNotificationScheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var updateRevision = 0

    private static let enabledKindsKey = "comiket.event-reminders.c108.enabled-kinds.v1"
    private static let settingsKey = "comiket.event-reminders.c108.settings.v2"

    init(
        scheduler: any ComiketNotificationScheduling = SystemComiketNotificationScheduler(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        let settings = Self.loadSettings(from: defaults)
        enabledKinds = settings.enabledKinds
        selectedTimings = settings.selectedTimings
        if settings.needsMigration {
            persistSelection()
        }
    }

    func isEnabled(_ kind: ComiketReminderKind) -> Bool {
        enabledKinds.contains(kind)
    }

    func timing(for kind: ComiketReminderKind) -> ComiketReminderTiming {
        selectedTimings[kind] ?? kind.defaultTiming
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

    func setTiming(_ timing: ComiketReminderTiming, for kind: ComiketReminderKind) async {
        let mutation = applyOptimisticTiming(timing, for: kind)
        await finishTimingSelection(mutation)
    }

    func setTimingOptimistically(_ timing: ComiketReminderTiming, for kind: ComiketReminderKind) {
        let mutation = applyOptimisticTiming(timing, for: kind)
        Task { [weak self] in
            await self?.finishTimingSelection(mutation)
        }
    }

    private func applyOptimisticSelection(
        _ enabled: Bool,
        for kind: ComiketReminderKind
    ) -> ReminderSelectionMutation {
        AppTrack.userIntent(
            .eventReminderChanged,
            data: [
                "event_number": ComiketEventReminderCatalog.eventNumber,
                "kind": kind.rawValue,
                "enabled": enabled,
            ]
        )
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

    private func applyOptimisticTiming(
        _ timing: ComiketReminderTiming,
        for kind: ComiketReminderKind
    ) -> ReminderTimingMutation {
        AppTrack.userIntent(
            .eventReminderChanged,
            data: [
                "event_number": ComiketEventReminderCatalog.eventNumber,
                "kind": kind.rawValue,
                "enabled": enabledKinds.contains(kind),
                "lead_minutes": timing.rawValue,
            ]
        )
        updateRevision += 1
        errorMessage = nil
        let previousSelectedTimings = selectedTimings
        selectedTimings[kind] = timing
        persistSelection()
        return ReminderTimingMutation(
            revision: updateRevision,
            kind: kind,
            previousSelectedTimings: previousSelectedTimings
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

    private func finishTimingSelection(_ mutation: ReminderTimingMutation) async {
        do {
            let authorization = await scheduler.authorization()
            guard mutation.revision == updateRevision else { return }
            state = state(for: authorization)
            guard enabledKinds.contains(mutation.kind), case .authorized = authorization else {
                return
            }
            try await scheduleSelection()
        } catch {
            guard mutation.revision == updateRevision else { return }
            selectedTimings = mutation.previousSelectedTimings
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
            let timings = Dictionary(
                uniqueKeysWithValues: enabledKinds.map { ($0, timing(for: $0)) }
            )
            let requests = ComiketEventReminderCatalog.requests(
                for: enabledKinds,
                timings: timings,
                now: now()
            )
            try await scheduler.replaceOwnedRequests(with: requests)
            guard scheduledRevision != updateRevision else { return }
        }
    }

    private func persistSelection() {
        let settings = PersistedReminderSettings(
            enabledKinds: enabledKinds.map(\.rawValue).sorted(),
            selectedTimings: Dictionary(
                uniqueKeysWithValues: selectedTimings.map { ($0.key.rawValue, $0.value.rawValue) }
            )
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private static func loadSettings(from defaults: UserDefaults) -> LoadedReminderSettings {
        if let data = defaults.data(forKey: settingsKey),
           let persisted = try? JSONDecoder().decode(PersistedReminderSettings.self, from: data)
        {
            let enabledValues = Set(persisted.enabledKinds)
            let enabledKinds = Set(
                ComiketReminderKind.allCases.filter { enabledValues.contains($0.rawValue) }
            )
            let selectedTimings: [ComiketReminderKind: ComiketReminderTiming] = Dictionary(
                uniqueKeysWithValues: persisted.selectedTimings.compactMap { entry in
                    let (rawKind, rawTiming) = entry
                    guard let kind = ComiketReminderKind(rawValue: rawKind),
                          let timing = ComiketReminderTiming(rawValue: rawTiming)
                    else { return nil }
                    return (kind, timing)
                }
            )
            return LoadedReminderSettings(
                enabledKinds: enabledKinds,
                selectedTimings: selectedTimings,
                needsMigration: false
            )
        }

        let legacyValues = Set(defaults.stringArray(forKey: enabledKindsKey) ?? [])
        return LoadedReminderSettings(
            enabledKinds: Set(
                ComiketReminderKind.allCases.filter { legacyValues.contains($0.rawValue) }
            ),
            selectedTimings: [:],
            needsMigration: !legacyValues.isEmpty
        )
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

private struct PersistedReminderSettings: Codable {
    let enabledKinds: [String]
    let selectedTimings: [String: Int]
}

private struct LoadedReminderSettings {
    let enabledKinds: Set<ComiketReminderKind>
    let selectedTimings: [ComiketReminderKind: ComiketReminderTiming]
    let needsMigration: Bool
}

private struct ReminderSelectionMutation: Sendable {
    let revision: Int
    let enabled: Bool
    let kind: ComiketReminderKind
    let previousEnabledKinds: Set<ComiketReminderKind>
}

private struct ReminderTimingMutation: Sendable {
    let revision: Int
    let kind: ComiketReminderKind
    let previousSelectedTimings: [ComiketReminderKind: ComiketReminderTiming]
}
