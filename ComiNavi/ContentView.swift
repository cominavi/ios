//
//  ContentView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import SwiftUI

/// The app's tabs. The raw values are persisted in scene storage, so keep
/// them stable across releases.
enum AppTab: String, Hashable {
    case map
    case explore
    case plans
    case profile
}

/// The one app shell. Every tab exists in every catalog state: Map and
/// Explore show the catalog loading surface until a catalog is ready, while
/// Shared Plans and Profile stay usable during discovery and downloads.
struct ContentView: View {
    @State private var catalogLibrary: CatalogLibrary
    @State private var sharedLocationInbox: SharedLocationInbox
    @SceneStorage("ContentView.selectedTab") private var selection: AppTab = .map
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
        TabView(selection: $selection) {
            Tab(
                "Map",
                image: LucideIcon.assetName(for: "map"),
                value: AppTab.map
            ) {
                catalogTab { circle in
                    MapView(
                        dataSource: circle,
                        selectedDay: $selectedDay,
                        eventDaySelector: eventDayBanner(for: circle),
                        sharedLocationInbox: sharedLocationInbox
                    )
                }
            }

            Tab(
                "Explore",
                image: LucideIcon.assetName(for: "safari"),
                value: AppTab.explore
            ) {
                catalogTab { circle in
                    ExploreView(dataSource: circle, selectedDay: $selectedDay) {
                        CatalogEventDayToolbarButton(
                            event: catalogLibrary.selectedEvent,
                            selectedDay: selectedDay
                        ) {
                            showsCatalogSettings = true
                        }
                    }
                }
            }

            Tab(
                "Shared Plans",
                image: LucideIcon.assetName(for: "list-checks"),
                value: AppTab.plans
            ) {
                SharedPlansScreen(
                    store: AppData.sharedPlanStore,
                    comiketNo: readyDataSource?.comiket.number,
                    currentUserID: AppData.profileStore.profile?.id
                )
            }

            Tab(value: AppTab.profile) {
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
        // iPad shows a sidebar the user can collapse into the tab bar instead
        // of a text-only floating bar over the map; iPhone keeps the tab bar.
        .tabViewStyle(.sidebarAdaptable)
        .accessibilityIdentifier("app-shell")
        .task {
            if catalogLibrary.phase == .idle {
                catalogLibrary.start()
            }
        }
        .onChange(of: catalogLibrary.errorMessage) { _, message in
            guard let message, readyDataSource != nil else { return }
            AppToast.showError(
                String(localized: "Catalog switch failed"),
                subtitle: message
            )
            catalogLibrary.dismissError()
        }
        .onChange(of: readyDataSourceID, initial: true) {
            restoreRememberedDay()
            handlePendingSharedLocation()
        }
        .onChange(of: selectedDay) { _, day in
            guard let circle = readyDataSource else { return }
            catalogLibrary.rememberSelectedDay(
                day,
                forEventNumber: circle.comiket.number,
                availableDayIndices: circle.comiket.days.map(\.dayIndex)
            )
        }
        .onChange(of: sharedLocationInbox.pending?.id, initial: true) {
            handlePendingSharedLocation()
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

    /// The open catalog, or nil while the first catalog is still loading. A
    /// catalog that is being replaced stays ready until its successor is.
    private var readyDataSource: CirclemsDataSource? {
        guard let dataSource = catalogLibrary.dataSource,
              dataSource.readiness == .ready
        else { return nil }
        return dataSource
    }

    private var readyDataSourceID: ObjectIdentifier? {
        readyDataSource.map(ObjectIdentifier.init)
    }

    /// Map and Explore depend on one catalog instance, so only they rebuild
    /// when the catalog changes. The tab selection and the Shared Plans and
    /// Profile navigation paths survive a Comiket switch.
    @ViewBuilder
    private func catalogTab<Content: View>(
        @ViewBuilder content: (CirclemsDataSource) -> Content
    ) -> some View {
        if let circle = readyDataSource {
            content(circle)
                .id(ObjectIdentifier(circle))
        } else {
            CatalogLibraryLoadingSurface(catalogLibrary: catalogLibrary)
        }
    }

    private func restoreRememberedDay() {
        guard let circle = readyDataSource,
              let rememberedDay = catalogLibrary.preferredDay(
                  forEventNumber: circle.comiket.number,
                  availableDayIndices: circle.comiket.days.map(\.dayIndex)
              ),
              rememberedDay != selectedDay
        else { return }

        selectedDay = rememberedDay
    }

    private func handlePendingSharedLocation() {
        guard let request = sharedLocationInbox.pending,
              let circle = readyDataSource
        else { return }
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

    private func eventDayBanner(for circle: CirclemsDataSource) -> CatalogEventDayBanner {
        CatalogEventDayBanner(
            event: catalogLibrary.selectedEvent,
            days: circle.comiket.days,
            selectedDay: selectedDay
        ) {
            showsCatalogSettings = true
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
