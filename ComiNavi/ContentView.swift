//
//  ContentView.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/12/24.
//

import SwiftUI

struct ContentView: View {
    @State private var catalogLibrary: CatalogLibrary
    @State private var selectedDay = 1
    @State private var showsCatalogSettings = false

    @MainActor
    init(catalogLibrary: CatalogLibrary = AppData.catalogLibrary) {
        _catalogLibrary = State(initialValue: catalogLibrary)
    }

    var body: some View {
        Group {
            if let circle = catalogLibrary.dataSource {
                CatalogContentView(
                    circle: circle,
                    catalogLibrary: catalogLibrary,
                    selectedDay: $selectedDay,
                    showsCatalogSettings: $showsCatalogSettings
                )
                .id(ObjectIdentifier(circle))
            } else {
                ProgressView("Opening catalog…")
            }
        }
        .overlay(alignment: .top) {
            if catalogLibrary.isSwitching,
               case .loading(let event) = catalogLibrary.phase
            {
                Label("Opening \(event.shortName)…", systemImage: "arrow.triangle.2.circlepath")
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

private struct CatalogContentView: View {
    private enum TabSelection: Hashable {
        case map
        case explore
        case profile
    }

    let circle: CirclemsDataSource
    let catalogLibrary: CatalogLibrary
    @State private var selection: TabSelection = .map
    @Binding var selectedDay: Int
    @Binding var showsCatalogSettings: Bool

    var body: some View {
        Group {
            switch circle.readiness {
            case .uninitialized:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing catalog…")
                        .foregroundStyle(.secondary)
                }

            case .downloading(progresses: let progresses):
                VStack(spacing: 16) {
                    ProgressView()

                    DownloadProgressView(progresses: progresses)

                    Text(
                        "Downloading \(catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog")) databases…"
                    )
                        .foregroundStyle(.secondary)

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                }
                .padding(.horizontal)
                .padding()

            case .initializing(let state):
                VStack(spacing: 8) {
                    ProgressView()
                    Text(
                        "Initializing \(catalogLibrary.selectedEvent?.shortName ?? String(localized: "catalog"))…"
                    )
                        .foregroundStyle(.secondary)

                    Text(state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    CatalogLoadingEventPicker(catalogLibrary: catalogLibrary)
                }

            case .ready:
                TabView(selection: $selection) {
                    Tab("Map", systemImage: "map", value: .map) {
                        VStack(spacing: 0) {
                            eventDayBanner

                            MapView(
                                dataSource: circle,
                                selectedDay: $selectedDay
                            )
                        }
                    }

                    Tab("Explore", systemImage: "safari", value: .explore) {
                        ExploreView(dataSource: circle, selectedDay: $selectedDay) {
                            eventDayBanner
                        }
                    }

                    Tab("Profile", systemImage: "person.circle", value: .profile) {
                        VStack(spacing: 0) {
                            eventDayBanner

                            ProfileScreen(catalogLibrary: catalogLibrary)
                        }
                    }
                }

            case .error(let error):
                ContentUnavailableView {
                    Label("Catalog unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        catalogLibrary.retry()
                    }
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
    }

    private var eventDayBanner: some View {
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
                            Label(event.displayName, systemImage: "checkmark")
                        } else {
                            Text(event.displayName)
                        }
                    }
                }
            } label: {
                Label("Choose another catalog", systemImage: "arrow.left.arrow.right")
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
