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
    private let catalogResetAction: CatalogResetAction?

    @MainActor
    init(
        catalogLibrary: CatalogLibrary = AppData.catalogLibrary,
        sharedLocationInbox: SharedLocationInbox = AppData.sharedLocationInbox,
        catalogResetAction: CatalogResetAction? = nil
    ) {
        _catalogLibrary = State(initialValue: catalogLibrary)
        _sharedLocationInbox = State(initialValue: sharedLocationInbox)
        self.catalogResetAction = catalogResetAction
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
            CatalogLibraryLoadingSurface(
                catalogLibrary: catalogLibrary,
                resetAction: catalogResetAction
            )
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

/// Lets the catalog failure surface offer EntryView's destructive
/// "Log Out & Reset" recovery without owning the logout flow.
struct CatalogResetAction {
    var isInProgress: Bool
    var issue: String?
    var request: () -> Void
}

/// The single loading and failure surface for the catalog tabs. It covers
/// discovery, download, opening, and failure with one string set and one
/// symbol, and every state with a known event list lets the user pick
/// another Comiket.
private struct CatalogLibraryLoadingSurface: View {
    let catalogLibrary: CatalogLibrary
    let resetAction: CatalogResetAction?

    var body: some View {
        switch catalogLibrary.phase {
        case .failed(let message):
            CatalogErrorSurface(
                symbolName: "exclamationmark.triangle.fill",
                title: String(localized: "Catalog unavailable"),
                message: resetAction?.issue ?? message,
                advice: catalogLibrary.failureRecovery == .redownload
                    ? String(localized: "Start a fresh download. The incomplete copy will be removed, then the new catalog will be verified before it opens.")
                    : String(localized: "Please try again.")
            ) {
                CatalogRecoveryButton(catalogLibrary: catalogLibrary)

                if let resetAction {
                    CatalogResetButton(action: resetAction)
                }

                CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
            }

        case .downloading(let event, let progress):
            downloadingSurface(eyebrow: event.shortName, progresses: [progress])

        case .loading(let event):
            // Circle.ms catalogs download inside the data source after the
            // library has handed it over, so its progress wins when present.
            if let progresses = dataSourceDownloadProgresses {
                downloadingSurface(eyebrow: event.shortName, progresses: progresses)
            } else {
                openingSurface(
                    eyebrow: event.shortName,
                    title: String(localized: "Opening catalog…")
                )
            }

        case .discovering:
            openingSurface(
                eyebrow: String(localized: "Catalog"),
                title: String(localized: "Finding available catalogs…")
            )

        case .idle, .ready:
            openingSurface(
                eyebrow: catalogLibrary.selectedEvent?.shortName
                    ?? String(localized: "Catalog"),
                title: String(localized: "Opening catalog…")
            )
        }
    }

    private var dataSourceDownloadProgresses: Readiness.Progresses? {
        guard case .downloading(let progresses)? = catalogLibrary.dataSource?.readiness,
              !progresses.isEmpty
        else { return nil }
        return progresses
    }

    private func openingSurface(eyebrow: String, title: String) -> some View {
        CatalogStatusSurface(
            symbolName: "map",
            eyebrow: eyebrow,
            title: title,
            subtitle: String(localized: "The map and the circle list open when the catalog is ready.")
        ) {
            CatalogActivityIndicator(accessibilityLabel: title)

            CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                .padding(.top, 24)
        }
    }

    private func downloadingSurface(
        eyebrow: String,
        progresses: Readiness.Progresses
    ) -> some View {
        CatalogStatusSurface(
            symbolName: "map",
            eyebrow: eyebrow,
            title: String(localized: "Downloading catalog…"),
            subtitle: String(localized: "This can take a few minutes. You can use Shared Plans and Profile in the meantime.")
        ) {
            DownloadProgressView(progresses: progresses)

            CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                .padding(.top, 24)
        }
    }
}

private struct CatalogResetButton: View {
    let action: CatalogResetAction

    var body: some View {
        FocusedActionButton(
            role: .destructive,
            emphasis: .secondary,
            tint: .red,
            action: action.request
        ) {
            if action.isInProgress {
                ProgressView()
                    .accessibilityLabel(Text("Logging out…"))
            } else {
                LucideLabel(
                    "Log Out & Reset",
                    icon: "person.crop.circle.badge.minus"
                )
            }
        }
        .disabled(action.isInProgress)
        .accessibilityHint(
            Text("Signs you out and removes downloaded catalogs from this device.")
        )
        .accessibilityIdentifier("catalog-log-out-reset")
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
                LucideLabel("Choose another Comiket", icon: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("catalog-loading-event-selector")
        }
    }
}

#Preview {
    ContentView()
}
