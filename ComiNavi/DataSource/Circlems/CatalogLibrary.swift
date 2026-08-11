import Foundation
import Observation

enum CatalogDataMode: String, CaseIterable, Hashable, Sendable {
    case cominavi
    case circlems

    #if DEBUG || COMINAVI_STAGING
    case demo
    #endif

    var displayName: String {
        switch self {
        case .cominavi:
            "ComiNavi"
        case .circlems:
            "Circle.ms"
        #if DEBUG || COMINAVI_STAGING
        case .demo:
            String(localized: "Demo data")
        #endif
        }
    }

    var detail: String {
        switch self {
        case .cominavi:
            String(localized: "Downloads the verified ComiNavi catalog for every signed-in account.")
        case .circlems:
            String(localized: "Downloads catalogs supported by Circle.ms.")
        #if DEBUG || COMINAVI_STAGING
        case .demo:
            String(localized: "Opens the bundled C104 catalog without a network connection.")
        #endif
        }
    }
}

struct CatalogEvent: Identifiable, Hashable, Sendable {
    /// Circle.ms's stable event identifier used by all event-scoped API calls.
    let id: Int
    /// The public Comiket number stored in the catalog database, such as 108.
    let number: Int

    var shortName: String { "C\(number)" }
    var displayName: String { String(localized: "Comic Market \(number)") }
    var scheduledDateRange: CatalogEventDateRange? { Self.knownDateRanges[number] }

    private static let knownDateRanges: [Int: CatalogEventDateRange] = [
        100: .init(start: (2022, 8, 13), end: (2022, 8, 14)),
        101: .init(start: (2022, 12, 30), end: (2022, 12, 31)),
        102: .init(start: (2023, 8, 12), end: (2023, 8, 13)),
        103: .init(start: (2023, 12, 30), end: (2023, 12, 31)),
        104: .init(start: (2024, 8, 11), end: (2024, 8, 12)),
        105: .init(start: (2024, 12, 29), end: (2024, 12, 30)),
        106: .init(start: (2025, 8, 16), end: (2025, 8, 17)),
        107: .init(start: (2025, 12, 30), end: (2025, 12, 31)),
        108: .init(start: (2026, 8, 15), end: (2026, 8, 16)),
    ]

    static func available(from response: CirclemsAPI.EventListResponseData) -> [CatalogEvent] {
        response.list
            .filter {
                $0.eventID <= response.latestEventID
                    && $0.eventNumber <= response.latestEventNumber
            }
            .map { CatalogEvent(id: $0.eventID, number: $0.eventNumber) }
            .uniqued(on: \.id)
            .sorted {
                if $0.number != $1.number { return $0.number > $1.number }
                return $0.id > $1.id
            }
    }

    static func preferred(in events: [CatalogEvent], persistedEventID: Int?) -> CatalogEvent? {
        events.first { $0.id == persistedEventID } ?? events.first
    }
}

struct CatalogEventDateRange: Hashable, Sendable {
    let start: DateComponents
    let end: DateComponents

    init(
        start: (year: Int, month: Int, day: Int),
        end: (year: Int, month: Int, day: Int)
    ) {
        self.start = DateComponents(year: start.year, month: start.month, day: start.day)
        self.end = DateComponents(year: end.year, month: end.month, day: end.day)
    }

    func dates(in calendar: Calendar) -> (start: Date, end: Date)? {
        guard let start = calendar.date(from: start),
              let end = calendar.date(from: end)
        else { return nil }

        return (start, end)
    }
}

protocol CatalogEventServicing: Sendable {
    func eventList() async throws -> CirclemsAPI.EventListResponse
    func catalogBase(eventID: Int) async throws -> CirclemsAPI.CatalogBaseResponse
}

struct CirclemsCatalogEventService: CatalogEventServicing {
    func eventList() async throws -> CirclemsAPI.EventListResponse {
        try await CirclemsAPI.getEventList()
    }

    func catalogBase(eventID: Int) async throws -> CirclemsAPI.CatalogBaseResponse {
        try await CirclemsAPI.getCatalogBase(eventId: eventID)
    }
}

protocol CatalogSource: Sendable {
    var mode: CatalogDataMode { get }
    func availableEvents() async throws -> [CatalogEvent]
    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration
}

extension CatalogSource {
    func configuration(for event: CatalogEvent) async throws -> CatalogDataSourceConfiguration {
        try await configuration(for: event, progress: nil)
    }
}

struct CirclemsCatalogSource: CatalogSource {
    let mode = CatalogDataMode.circlems
    private let service: any CatalogEventServicing

    init(service: any CatalogEventServicing = CirclemsCatalogEventService()) {
        self.service = service
    }

    func availableEvents() async throws -> [CatalogEvent] {
        let response = try await service.eventList()
        let events = CatalogEvent.available(from: response.response)

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cominavi-ui-testing-event-probe") {
            let supported = events.map(\.shortName).joined(separator: ", ")
            NSLog(
                "Circle.ms event probe: LatestEventId=%d LatestEventNo=C%d supported=[%@]",
                response.response.latestEventID,
                response.response.latestEventNumber,
                supported
            )
        }
        #endif

        return events
    }

    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        let response = try await service.catalogBase(eventID: event.id)
        guard let mainURL = URL(string: response.response.url.textdbSqlite3UrlSsl),
              let imageURL = URL(string: response.response.url.imagedb1UrlSsl)
        else {
            throw CatalogLibraryError.invalidDatabaseURL
        }

        return CatalogDataSourceConfiguration(
            eventID: event.id,
            eventNumber: event.number,
            main: .init(
                digest: response.response.md5.textdbSqlite3UrlSsl,
                origin: .remote(mainURL)
            ),
            image: .init(
                digest: response.response.md5.imagedb1UrlSsl,
                origin: .remote(imageURL)
            ),
            enrichment: CatalogResourceLocator.url(
                named: "crawl-c\(event.number)-shinagaki.json"
            )
            .map {
                CatalogEnrichmentConfiguration(
                    resourceURL: $0,
                    isRequired: false
                )
            },
            allowsBookmarkSync: true,
            allowsRemoteMetadata: true,
            // Provider mirroring remains opt-in after an explicit import/link
            // confirmation; merely selecting the debug source is not consent.
            allowsCirclemsFavoriteMirror: false
        )
    }
}

#if DEBUG || COMINAVI_STAGING
struct DemoCatalogSource: CatalogSource {
    static let c104 = CatalogEvent(id: 190, number: 104)

    let mode = CatalogDataMode.demo
    private let resourceDirectory: URL?

    init(resourceDirectory: URL? = nil) {
        self.resourceDirectory = resourceDirectory
    }

    func availableEvents() async throws -> [CatalogEvent] {
        [Self.c104]
    }

    func configuration(
        for event: CatalogEvent,
        progress: (@MainActor @Sendable (Readiness.Progress) -> Void)?
    ) async throws -> CatalogDataSourceConfiguration {
        guard event == Self.c104 else {
            throw CatalogLibraryError.demoEventUnavailable
        }

        let mainURL = try resourceURL(named: "demo-c104-main.sqlite")
        let imageURL = try resourceURL(named: "demo-c104-images.sqlite")
        return CatalogDataSourceConfiguration(
            eventID: event.id,
            eventNumber: event.number,
            main: .init(
                digest: "b30db58d09de7095fbeba0e6132565928327388975c4c0940e6f3ed63219f146",
                origin: .local(mainURL)
            ),
            image: .init(
                digest: "98c3a14c99d01a63c82200b3f5c59c702c4ee4782f5f886cd050f85bb04229c8",
                origin: .local(imageURL)
            ),
            enrichment: nil,
            allowsBookmarkSync: false,
            allowsRemoteMetadata: false
        )
    }

    private func resourceURL(named name: String) throws -> URL {
        guard let url = CatalogResourceLocator.url(
            named: name,
            resourceDirectory: resourceDirectory
        ) else {
            throw CatalogLibraryError.missingDemoDatabase(name)
        }
        return url
    }
}

#endif

enum CatalogResourceLocator {
    static func url(
        named name: String,
        resourceDirectory: URL? = nil
    ) -> URL? {
        if let resourceDirectory {
            let url = resourceDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        guard let resources = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}

@MainActor
@Observable
final class CatalogLibrary {
    enum Phase: Equatable {
        case idle
        case discovering
        case loading(CatalogEvent)
        case downloading(CatalogEvent, Readiness.Progress)
        case ready
        case failed(String)
    }

    private(set) var mode: CatalogDataMode
    private(set) var events: [CatalogEvent] = []
    private(set) var selectedEvent: CatalogEvent?
    private(set) var dataSource: CirclemsDataSource?
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?

    @ObservationIgnored private let sources: [CatalogDataMode: any CatalogSource]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDataSource: CirclemsDataSource?

    init(
        service: any CatalogEventServicing = CirclemsCatalogEventService(),
        defaults: UserDefaults = .standard,
        initialMode: CatalogDataMode? = nil
    ) {
        var sources: [CatalogDataMode: any CatalogSource] = [
            .cominavi: CominaviCatalogSource(),
        ]
        #if DEBUG || COMINAVI_STAGING
        sources[.circlems] = CirclemsCatalogSource(service: service)
        if initialMode == .demo
            || ProcessInfo.processInfo.arguments.contains("-cominavi-demo-data")
        {
            // The bundled catalog is a deterministic automation fixture, not
            // an end-user data source.
            sources[.demo] = DemoCatalogSource()
        }
        #endif
        self.sources = sources
        self.defaults = defaults
        mode = Self.initialMode(
            explicit: initialMode,
            defaults: defaults,
            availableModes: Set(sources.keys)
        )
    }

    init(
        sources: [CatalogDataMode: any CatalogSource],
        defaults: UserDefaults,
        initialMode: CatalogDataMode
    ) {
        precondition(sources[initialMode] != nil, "The initial catalog mode needs a source adapter.")
        self.sources = sources
        self.defaults = defaults
        mode = initialMode
    }

    var availableModes: [CatalogDataMode] {
        CatalogDataMode.allCases.filter { sources[$0] != nil }
    }

    var isSwitching: Bool {
        switch phase {
        case .loading, .downloading:
            return dataSource?.readiness == .ready
        default:
            break
        }
        return false
    }

    func start() {
        guard phase == .idle || dataSource == nil,
              let source = sources[mode]
        else { return }

        operationTask?.cancel()
        phase = .discovering
        errorMessage = nil
        operationTask = Task { [weak self, source] in
            do {
                let availableEvents = try await source.availableEvents()
                try Task.checkCancellation()
                guard let self else { return }

                guard !availableEvents.isEmpty else {
                    throw CatalogLibraryError.noAvailableCatalogs
                }

                self.events = availableEvents
                let persistedEventID = self.defaults.object(
                    forKey: self.selectedEventDefaultsKey
                ) as? Int
                let preferredEvent = CatalogEvent.preferred(
                    in: availableEvents,
                    persistedEventID: persistedEventID
                ) ?? availableEvents[0]
                self.load(preferredEvent)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.fallbackToCominaviCatalogIfNeeded(for: error) {
                    return
                }
                self.phase = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func select(_ event: CatalogEvent) {
        guard events.contains(event), event != selectedEvent else { return }
        load(event)
    }

    func selectMode(_ newMode: CatalogDataMode) {
        guard newMode != mode, sources[newMode] != nil else { return }

        operationTask?.cancel()
        pendingDataSource?.cancelPreparation()
        pendingDataSource = nil
        dataSource?.cancelPreparation()
        dataSource = nil
        events = []
        selectedEvent = nil
        phase = .idle
        errorMessage = nil
        mode = newMode
        defaults.set(newMode.rawValue, forKey: modeDefaultsKey)
    }

    func retry() {
        if let selectedEvent {
            load(selectedEvent)
        } else {
            phase = .idle
            start()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func reset() {
        operationTask?.cancel()
        operationTask = nil
        pendingDataSource?.cancelPreparation()
        pendingDataSource = nil
        dataSource?.cancelPreparation()
        dataSource = nil
        events = []
        selectedEvent = nil
        phase = .idle
        errorMessage = nil
    }

    private func load(_ event: CatalogEvent) {
        guard let source = sources[mode] else { return }

        operationTask?.cancel()
        pendingDataSource?.cancelPreparation()
        pendingDataSource = nil
        if dataSource?.readiness != .ready {
            dataSource?.cancelPreparation()
            dataSource = nil
            selectedEvent = nil
        }
        phase = .loading(event)
        errorMessage = nil

        operationTask = Task { [weak self, source] in
            var candidate: CirclemsDataSource?
            do {
                let configuration = try await source.configuration(
                    for: event,
                    progress: { [weak self] progress in
                        guard let self, self.phase != .ready else { return }
                        self.phase = .downloading(event, progress)
                    }
                )
                try Task.checkCancellation()
                guard let self else { return }

                self.phase = .loading(event)

                let nextDataSource = CirclemsDataSource(configuration: configuration)
                candidate = nextDataSource
                self.pendingDataSource = nextDataSource

                if self.dataSource?.readiness != .ready {
                    self.dataSource = nextDataSource
                    self.selectedEvent = event
                }

                try await nextDataSource.waitUntilReady()
                try Task.checkCancellation()
                guard self.pendingDataSource === nextDataSource else {
                    throw CancellationError()
                }

                if let currentDataSource = self.dataSource,
                   currentDataSource !== nextDataSource
                {
                    currentDataSource.cancelPreparation()
                }
                self.dataSource = nextDataSource
                self.pendingDataSource = nil
                self.selectedEvent = event
                self.defaults.set(event.id, forKey: self.selectedEventDefaultsKey)
                self.phase = .ready
            } catch is CancellationError {
                candidate?.cancelPreparation()
                if let self, self.pendingDataSource === candidate {
                    self.pendingDataSource = nil
                }
                return
            } catch {
                guard let self else { return }
                candidate?.cancelPreparation()
                if self.pendingDataSource === candidate {
                    self.pendingDataSource = nil
                }
                if self.fallbackToCominaviCatalogIfNeeded(for: error) {
                    return
                }
                self.errorMessage = String(
                    localized: "Could not load \(event.shortName): \(error.localizedDescription)"
                )
                self.phase = self.dataSource?.readiness != .ready
                    ? .failed(error.localizedDescription)
                    : .ready
            }
        }
    }

    @discardableResult
    private func fallbackToCominaviCatalogIfNeeded(for error: Error) -> Bool {
        guard mode == .circlems,
              error as? CirclemsAPIAuthorizationError == .accessTokenRequired,
              sources[.cominavi] != nil
        else { return false }

        pendingDataSource?.cancelPreparation()
        pendingDataSource = nil
        dataSource?.cancelPreparation()
        dataSource = nil
        events = []
        selectedEvent = nil
        phase = .idle
        errorMessage = nil
        mode = .cominavi
        defaults.set(CatalogDataMode.cominavi.rawValue, forKey: modeDefaultsKey)
        operationTask = nil
        start()
        return true
    }

    private var modeDefaultsKey: String {
        "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)"
    }

    private var selectedEventDefaultsKey: String {
        "CatalogLibrary.selectedEventID.\(AppEnvironment.current.storageNamespace).\(mode.rawValue)"
    }

    private static func initialMode(
        explicit: CatalogDataMode?,
        defaults: UserDefaults,
        availableModes: Set<CatalogDataMode>
    ) -> CatalogDataMode {
        if let explicit, availableModes.contains(explicit) {
            return explicit
        }

        #if DEBUG || COMINAVI_STAGING
        if ProcessInfo.processInfo.arguments.contains("-cominavi-circlems-data"),
           availableModes.contains(.circlems)
        {
            return .circlems
        }
        #endif

        #if DEBUG || COMINAVI_STAGING
        if ProcessInfo.processInfo.arguments.contains("-cominavi-demo-data"),
           availableModes.contains(.demo)
        {
            return .demo
        }
        #endif

        let key = "CatalogLibrary.mode.\(AppEnvironment.current.storageNamespace)"
        if let rawValue = defaults.string(forKey: key),
           let persisted = CatalogDataMode(rawValue: rawValue),
           availableModes.contains(persisted)
        {
            return persisted
        }
        return availableModes.contains(.cominavi) ? .cominavi : .circlems
    }
}

enum CatalogLibraryError: LocalizedError {
    case noAvailableCatalogs
    case invalidDatabaseURL
    case demoEventUnavailable
    case missingDemoDatabase(String)

    var errorDescription: String? {
        switch self {
        case .noAvailableCatalogs:
            String(localized: "Circle.ms did not return any currently viewable Comiket catalogs.")
        case .invalidDatabaseURL:
            String(localized: "Circle.ms returned an invalid catalog database URL.")
        case .demoEventUnavailable:
            String(localized: "This event is not included in the demo catalog.")
        case .missingDemoDatabase(let name):
            String(
                localized: "The demo catalog is missing \(name). Run Scripts/prepare-demo-catalog.sh before building."
            )
        }
    }
}

private extension Sequence {
    func uniqued<Key: Hashable>(on key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
