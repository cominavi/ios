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

            Tab(value: .profile) {
                NavigationStack {
                    ProfileScreen(
                        catalogLibrary: catalogLibrary,
                        sharedLocationInbox: sharedLocationInbox
                    )
                }
            } label: {
                ProfileTabLabel(profileStore: AppData.profileStore)
            }
        }
        .accessibilityIdentifier("catalog-independent-shell")
        .task {
            if catalogLibrary.phase == .idle {
                catalogLibrary.start()
            }
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
        .onChange(of: catalogLibrary.errorMessage) { _, message in
            guard let message, catalogLibrary.dataSource?.readiness == .ready else { return }
            AppToast.showError(
                String(localized: "Catalog switch failed"),
                subtitle: message
            )
            catalogLibrary.dismissError()
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
    }
}

private struct CatalogLibraryLoadingSurface: View {
    let catalogLibrary: CatalogLibrary

    var body: some View {
        switch catalogLibrary.phase {
        case .failed(let message):
            CatalogErrorSurface(
                symbolName: "exclamationmark.triangle.fill",
                title: String(localized: "Catalog unavailable"),
                message: message,
                advice: catalogLibrary.failureRecovery == .redownload
                    ? String(localized: "Start a fresh download. The incomplete copy will be removed, then the new catalog will be verified before it opens.")
                    : String(localized: "Please try again.")
            ) {
                CatalogRecoveryButton(catalogLibrary: catalogLibrary)
            }

        case .loading(let event):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                CatalogActivityIndicator(
                    accessibilityLabel: String(localized: "Opening catalog…")
                )
            }

        case .downloading(let event, let progress):
            CatalogStatusSurface(
                symbolName: "arrow.down.circle.fill",
                eyebrow: event.shortName,
                title: String(localized: "Downloading catalog…"),
                subtitle: String(localized: "Downloading the catalog, this may take a while…")
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
                CatalogActivityIndicator(
                    accessibilityLabel: String(localized: "Finding available catalogs…")
                )
            }

        case .idle, .ready:
            CatalogStatusSurface(
                symbolName: "circle.dotted",
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Opening catalog…"),
                subtitle: String(localized: "Preparing catalog…")
            ) {
                CatalogActivityIndicator(
                    accessibilityLabel: String(localized: "Opening catalog…")
                )
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
                    CatalogActivityIndicator(
                        accessibilityLabel: String(localized: "Preparing catalog…")
                    )

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                        .padding(.top, 24)
                }

            case .downloading(let progresses):
                let eventName =
                    catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog")
                CatalogStatusSurface(
                    symbolName: "arrow.down.circle.fill",
                    eyebrow: eventName,
                    title: String(localized: "Downloading\ncatalog"),
                    subtitle: String(localized: "Downloading the catalog, this may take a while…")
                ) {
                    DownloadProgressView(progresses: progresses)
                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                        .padding(.top, 24)
                }

            case .initializing(let state):
                let eventName =
                    catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog")
                CatalogStatusSurface(
                    symbolName: "map",
                    eyebrow: eventName,
                    title: String(localized: "Preparing catalog…"),
                    subtitle: state
                ) {
                    CatalogActivityIndicator(accessibilityLabel: state)

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

                    Tab(value: .profile) {
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
                    } label: {
                        ProfileTabLabel(profileStore: AppData.profileStore)
                    }
                }

            case .error(let error):
                CatalogErrorSurface(
                    symbolName: "exclamationmark.triangle.fill",
                    title: String(localized: "Catalog unavailable"),
                    message: error,
                    advice: catalogLibrary.failureRecovery == .redownload
                        ? String(localized: "Start a fresh download. The incomplete copy will be removed, then the new catalog will be verified before it opens.")
                        : String(localized: "Please try again.")
                ) {
                    CatalogRecoveryButton(catalogLibrary: catalogLibrary)

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

private struct CatalogRecoveryButton: View {
    let catalogLibrary: CatalogLibrary

    var body: some View {
        if catalogLibrary.failureRecovery == .redownload {
            FocusedActionButton {
                catalogLibrary.retry()
            } label: {
                LucideLabel("Download Again", icon: "download")
            }
            .accessibilityHint(
                Text("Discards the incomplete download and downloads the catalog from the beginning.")
            )
        } else {
            FocusedActionButton {
                catalogLibrary.retry()
            } label: {
                LucideLabel("Try Again", icon: "arrow.clockwise")
            }
        }
    }
}

private struct ProfileTabLabel: View {
    let profileStore: CominaviProfileStore

    var body: some View {
        Label {
            Text("Profile")
        } icon: {
            if let avatarURL = profileStore.profile?.avatarURL {
                AuthenticatedProfileAvatar(
                    url: avatarURL,
                    size: 24,
                    revision: profileStore.profile?.revision
                )
                    .accessibilityHidden(true)
            } else {
                Image(LucideIcon.assetName(for: "person.circle"))
            }
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
            .accessibilityIdentifier("catalog-loading-event-selector")
        }
    }
}

#Preview {
    ContentView()
}
