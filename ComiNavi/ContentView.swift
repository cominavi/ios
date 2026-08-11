//
//  ContentView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import SwiftUI

struct CatalogIndependentContentView: View {
    private enum TabSelection: Hashable {
        case catalog
        case plans
        case profile
    }

    let catalogLibrary: CatalogLibrary
    let sharedLocationInbox: SharedLocationInbox
    @State private var selection: TabSelection = .plans

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                "Catalog",
                image: LucideIcon.assetName(for: "map"),
                value: .catalog
            ) {
                CatalogLibraryLoadingSurface(catalogLibrary: catalogLibrary)
            }

            Tab(
                "共有プラン",
                image: LucideIcon.assetName(for: "list-checks"),
                value: .plans
            ) {
                SharedPlansScreen(
                    store: AppData.sharedPlanStore,
                    comiketNo: nil,
                    currentUserID: AppData.profileStore.profile?.id
                )
            }

            Tab(
                "Profile",
                image: LucideIcon.assetName(for: "person.circle"),
                value: .profile
            ) {
                NavigationStack {
                    ProfileScreen(
                        catalogLibrary: catalogLibrary,
                        sharedLocationInbox: sharedLocationInbox
                    )
                }
            }
        }
        .accessibilityIdentifier("catalog-independent-shell")
        .task {
            catalogLibrary.start()
        }
    }
}

struct ContentView: View {
    @State private var catalogLibrary: CatalogLibrary
    @State private var sharedLocationInbox: SharedLocationInbox
    @State private var selectedDay = 1
    @State private var showsCatalogSettings = false

    @MainActor
    init(
        catalogLibrary: CatalogLibrary = AppData.catalogLibrary,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox
    ) {
        _catalogLibrary = State(initialValue: catalogLibrary)
        _sharedLocationInbox = State(initialValue: sharedLocationInbox)
    }

    var body: some View {
        Group {
            if let circle = catalogLibrary.dataSource {
                CatalogContentView(
                    circle: circle,
                    catalogLibrary: catalogLibrary,
                    sharedLocationInbox: sharedLocationInbox,
                    selectedDay: $selectedDay,
                    showsCatalogSettings: $showsCatalogSettings
                )
                .id(ObjectIdentifier(circle))
            } else {
                CatalogLibraryLoadingSurface(catalogLibrary: catalogLibrary)
            }
        }
        .overlay(alignment: .top) {
            if catalogLibrary.isSwitching,
               let event = catalogLibrary.phase.eventBeingLoaded
            {
                LucideLabel("Opening \(event.shortName)…", icon: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .safeAreaPadding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .alert(
            "Catalog switch failed",
            isPresented: Binding(
                get: { catalogLibrary.errorMessage != nil },
                set: { if !$0 { catalogLibrary.dismissError() } }
            )
        ) {
            Button("OK") {
                catalogLibrary.dismissError()
            }
        } message: {
            Text(catalogLibrary.errorMessage ?? String(localized: "Please try again."))
        }
        .sheet(isPresented: $showsCatalogSettings) {
            CatalogEventDaySheet(
                catalogLibrary: catalogLibrary,
                selectedDay: $selectedDay
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .animation(.default, value: catalogLibrary.phase)
    }
}

private struct CatalogLibraryLoadingSurface: View {
    let catalogLibrary: CatalogLibrary

    var body: some View {
        switch catalogLibrary.phase {
        case .failed(let message):
            CatalogErrorSurface(
                symbolName: "exclamationmark.triangle.fill",
                title: String(localized: "Catalogs unavailable"),
                message: message,
                advice: String(localized: "Please try again.")
            ) {
                Button {
                    catalogLibrary.retry()
                } label: {
                    LucideLabel("Try Again", icon: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.accentColor)
            }

        case .loading(let event):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(String(localized: "Opening catalog…")))
            }

        case .downloading(let event, let progress):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Downloading catalog…"),
                subtitle: String(localized: "The previous catalog remains available until verification finishes.")
            ) {
                DownloadProgressView(progresses: [progress])
            }

        case .discovering:
            CatalogStatusSurface(
                symbolName: "sparkles",
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Finding available catalogs…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(String(localized: "Finding available catalogs…")))
            }

        case .idle, .ready:
            CatalogStatusSurface(
                symbolName: "circle.dotted",
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(String(localized: "Opening catalog…")))
            }
        }
    }
}

private extension CatalogLibrary.Phase {
    var eventBeingLoaded: CatalogEvent? {
        switch self {
        case .loading(let event), .downloading(let event, _): event
        default: nil
        }
    }
}

private struct CatalogContentView: View {
    private enum TabSelection: Hashable {
        case map
        case explore
        case plans
        case profile
    }

    let circle: CirclemsDataSource
    let catalogLibrary: CatalogLibrary
    let sharedLocationInbox: SharedLocationInbox
    @State private var selection: TabSelection = .map
    @Binding var selectedDay: Int
    @Binding var showsCatalogSettings: Bool

    var body: some View {
        Group {
            switch circle.readiness {
            case .uninitialized:
                CatalogStatusSurface(
                    symbolName: "circle.dotted",
                    eyebrow: catalogLibrary.selectedEvent?.shortName
                        ?? String(localized: "Catalog"),
                    title: String(localized: "Preparing catalog…"),
                    subtitle: String(localized: "Opening catalog…")
                ) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel(Text(String(localized: "Preparing catalog…")))

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                        .padding(.top, 24)
                }

            case .downloading(let progresses):
                let eventName =
                    catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog")
                CatalogStatusSurface(
                    symbolName: "arrow.down.circle.fill",
                    eyebrow: eventName,
                    title: String(localized: "Downloading\ndatabases"),
                    subtitle: String.localizedStringWithFormat(
                        String(localized: "Downloading %@ databases…"),
                        eventName
                    )
                ) {
                    DownloadProgressView(progresses: progresses)
                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                        .padding(.top, 24)
                }

            case .initializing(let state):
                let eventName =
                    catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog")
                CatalogStatusSurface(
                    symbolName: "gearshape.2.fill",
                    eyebrow: eventName,
                    title: String(localized: "Initializing \(eventName)…"),
                    subtitle: state
                ) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel(Text(state))

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                        .padding(.top, 24)
                }

            case .ready:
                TabView(selection: $selection) {
                    Tab(
                        "Map",
                        image: LucideIcon.assetName(for: "map"),
                        value: .map
                    ) {
                        MapView(
                            dataSource: circle,
                            selectedDay: $selectedDay,
                            eventDaySelector: eventDayBanner,
                            sharedLocationInbox: sharedLocationInbox
                        )
                    }

                    Tab(
                        "Explore",
                        image: LucideIcon.assetName(for: "safari"),
                        value: .explore
                    ) {
                        ExploreView(dataSource: circle, selectedDay: $selectedDay) {
                            CatalogEventDayBanner(
                                event: catalogLibrary.selectedEvent,
                                days: circle.comiket.days,
                                selectedDay: selectedDay
                            ) {
                                showsCatalogSettings = true
                            }
                        }
                    }

                    Tab(
                        "共有プラン",
                        image: LucideIcon.assetName(for: "list-checks"),
                        value: .plans
                    ) {
                        SharedPlansScreen(
                            store: AppData.sharedPlanStore,
                            comiketNo: circle.comiket.number,
                            currentUserID: AppData.profileStore.profile?.id
                        )
                    }

                    Tab(
                        "Profile",
                        image: LucideIcon.assetName(for: "person.circle"),
                        value: .profile
                    ) {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                eventDayBanner
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)

                            NavigationStack {
                                ProfileScreen(
                                    catalogLibrary: catalogLibrary,
                                    sharedLocationInbox: sharedLocationInbox
                                )
                            }
                        }
                    }
                }

            case .error(let error):
                CatalogErrorSurface(
                    symbolName: "exclamationmark.triangle.fill",
                    title: String(localized: "Catalog unavailable"),
                    message: error,
                    advice: String(localized: "Please try again.")
                ) {
                    Button {
                        catalogLibrary.retry()
                    } label: {
                        LucideLabel("Try Again", icon: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.accentColor)

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                }
            }
        }
        .onChange(of: circle.readiness, initial: true) {
            guard case .ready = circle.readiness,
                let days = circle.comiket?.days,
                let firstDay = days.first,
                !days.contains(where: { $0.dayIndex == selectedDay })
            else { return }

            selectedDay = firstDay.dayIndex
        }
        .onChange(of: sharedLocationInbox.pending?.id, initial: true) {
            handlePendingSharedLocation()
        }
    }

    private func handlePendingSharedLocation() {
        guard let request = sharedLocationInbox.pending else { return }
        let location = request.location

        guard circle.comiket.number == location.eventNumber else {
            guard
                let event = catalogLibrary.events.first(where: {
                    $0.number == location.eventNumber
                })
            else {
                sharedLocationInbox.fail(
                    request.id,
                    with: .unsupportedEvent(location.eventNumber)
                )
                return
            }
            catalogLibrary.select(event)
            return
        }

        selectedDay = location.sceneID.day
        selection = .map
    }

    private var eventDayBanner: CatalogEventDayBanner {
        CatalogEventDayBanner(
            event: catalogLibrary.selectedEvent,
            days: circle.comiket.days,
            selectedDay: selectedDay
        ) {
            showsCatalogSettings = true
        }
    }
}

private struct CatalogLoadingEventPicker: View {
    let catalogLibrary: CatalogLibrary

    var body: some View {
        if catalogLibrary.events.count > 1 {
            Menu {
                ForEach(catalogLibrary.events) { event in
                    Button {
                        catalogLibrary.select(event)
                    } label: {
                        if event == catalogLibrary.selectedEvent {
                            LucideLabel(verbatim: event.displayName, icon: "checkmark")
                        } else {
                            Text(event.displayName)
                        }
                    }
                }
            } label: {
                LucideLabel("Choose another catalog", icon: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .disabled(catalogLibrary.isSwitching)
            .accessibilityIdentifier("catalog-loading-event-selector")
        }
    }
}

#Preview {
    ContentView()
}
