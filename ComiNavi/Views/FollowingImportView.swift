import SwiftUI
import UIKit

struct FollowingImportView: View {
    let dataSource: CirclemsDataSource
    @State private var model: FollowingImportModel
    @State private var isShowingImportForm = false

    init(dataSource: CirclemsDataSource) {
        self.dataSource = dataSource
        _model = State(initialValue: FollowingImportModel(dataSource: dataSource))
    }

    var body: some View {
        Group {
            switch model.activity {
            case .loading:
                loadingSurface
            case .importing:
                importingSurface
            case .idle, .favoriting:
                readyContent
            }
        }
        .navigationTitle("X followed circles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { importToolbar }
        .task { await model.load() }
        .onChange(of: model.importState?.importedAt) { oldValue, newValue in
            guard oldValue != newValue, newValue != nil else { return }
            isShowingImportForm = false
        }
        .onChange(of: model.errorMessage) { _, message in
            guard let message else { return }
            AppToast.showError(
                String(localized: "Could not update followed circles"),
                subtitle: message
            )
            model.dismissError()
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if isShowingImportForm || model.importState == nil {
            importSurface
        } else if model.importedCircles.isEmpty {
            emptyResultsSurface
        } else {
            importedCirclesList
        }
    }

    private var loadingSurface: some View {
        FocusedActionSurface(
            symbolName: "person.2.crop.square.stack",
            animatesBackdrop: true
        ) {
            Text("X followed circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Preparing catalog…")
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            CatalogActivityIndicator(accessibilityLabel: "Preparing catalog…")
                .padding(.top, 30)
        }
        .accessibilityIdentifier("following-import-loading")
    }

    private var importingSurface: some View {
        FocusedActionSurface(
            symbolName: "person.2.crop.square.stack",
            animatesBackdrop: true
        ) {
            Text("Import followed circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Import the public X accounts you follow and match them to this catalog on your device."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)

            CatalogActivityIndicator(accessibilityLabel: "Import followed circles")
                .padding(.top, 30)
        }
        .accessibilityIdentifier("following-import-progress")
    }

    private var importSurface: some View {
        FocusedActionSurface(symbolName: "person.2.crop.square.stack") {
            Text("Find followed circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Import an X account to find circles it follows in this catalog.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(verbatim: "@")
                        .foregroundStyle(.secondary)

                    TextField("username", text: $model.twitterUserName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.go)
                        .onSubmit(model.importNow)
                        .accessibilityIdentifier("following-import-username")
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 14)
                )

                FocusedActionButton(action: model.importNow) {
                    LucideLabel(
                        "Import followed circles",
                        icon: "arrow.down.circle.fill"
                    )
                }
                .disabled(!model.canImport)
                .accessibilityIdentifier("following-import-start")
            }
            .padding(.top, 30)

            Group {
                if let availableAt = model.manualImportAvailableAt {
                    Text(
                        "Manual import is available after \(availableAt.formatted(date: .abbreviated, time: .shortened)). Nothing will start automatically."
                    )
                } else {
                    Text(
                        "Imports start only when you tap the button. They are limited to once every six hours."
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

            Text(
                "ComiNavi sends your Circle.ms session only to cominavi.net for verification. X accounts are matched to circles on this device. Imports are limited to once every six hours."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
        .accessibilityIdentifier("following-import-form")
    }

    private var emptyResultsSurface: some View {
        FocusedActionSurface(symbolName: "person.slash") {
            Text("No imported circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Import an X account to find circles it follows in this catalog.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            FocusedActionButton(action: showImportForm) {
                LucideLabel("Import", icon: "arrow.down.circle.fill")
            }
            .padding(.top, 28)
        }
        .accessibilityIdentifier("following-import-empty")
    }

    private var importedCirclesList: some View {
        List {
            if !model.importedCircles.isEmpty {
                Section("Favorite imported circles") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(BookmarkColor.selectableColors) { color in
                                Button {
                                    model.selectedColor = color
                                } label: {
                                    Circle()
                                        .fill(color.swiftUIColor)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if model.selectedColor == color {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.white)
                                                    .shadow(radius: 1)
                                            }
                                        }
                                        .overlay {
                                            Circle().stroke(.primary.opacity(0.16), lineWidth: 0.5)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(color.displayName)
                                .accessibilityAddTraits(
                                    model.selectedColor == color ? .isSelected : []
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)

                    Button(action: model.favoriteAll) {
                        Label("Favorite all imported circles", systemImage: "star.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(model.selectedColor.swiftUIColor)
                    }
                    .disabled(model.activity != .idle)
                    .accessibilityIdentifier("following-import-favorite-all")
                }
            }

            Section {
                ForEach(model.importedCircles) { importedCircle in
                    HStack(alignment: .top, spacing: 10) {
                        NavigationLink {
                            CircleDetailView(
                                circles: importedCircle.circles,
                                dataSource: dataSource
                            )
                        } label: {
                            FollowingImportedCircleRow(
                                importedCircle: importedCircle,
                                dataSource: dataSource,
                                favoriteColor: model.favoriteColor(for: importedCircle)
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.favorite(importedCircle)
                        } label: {
                            Image(systemName: model.favoriteColor(for: importedCircle) == nil
                                ? "star"
                                : "star.fill")
                                .font(.title3)
                                .foregroundStyle(
                                    model.favoriteColor(for: importedCircle)?.swiftUIColor
                                        ?? model.selectedColor.swiftUIColor
                                )
                                .frame(width: 36, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.activity != .idle)
                        .accessibilityLabel("Favorite this circle")
                    }
                }
            } header: {
                Text("Imported circles (\(model.importedPublicCircleCount))")
            } footer: {
                if let importState = model.importState {
                    Text(
                        "Last successful import: \(importState.importedAt.formatted(date: .abbreviated, time: .shortened)). Existing circles stay in this list when later imports add new matches."
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        if model.activity == .idle, model.importState != nil {
            if isShowingImportForm {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingImportForm = false }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", systemImage: "arrow.down.circle") {
                        showImportForm()
                    }
                    .accessibilityIdentifier("following-import-open-form")
                }
            }
        }
    }

    private func showImportForm() {
        isShowingImportForm = true
    }
}

private struct FollowingImportedCircleRow: View {
    let importedCircle: FollowingImportedCircle
    let dataSource: CirclemsDataSource
    let favoriteColor: BookmarkColor?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FollowingImportedCircleArtwork(
                circle: importedCircle.circle,
                dataSource: dataSource,
                favoriteColor: favoriteColor
            )
            .frame(width: 66)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let placement = placementLabel {
                    Text(placement)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                ForEach(importedCircle.sources.prefix(2), id: \.twitterUserID) { source in
                    HStack(spacing: 6) {
                        AsyncImage(url: source.profilePictureURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color(uiColor: .secondarySystemFill))
                        }
                        .frame(width: 22, height: 22)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(source.twitterDisplayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("@\(source.twitterUserName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
    }

    private var placementLabel: String? {
        guard let blockID = importedCircle.circle.blockId,
              let block = dataSource.comiket.blocks.first(where: {
                  $0.externalBlockId == blockID
              }),
              let spaceNumber = importedCircle.circle.spaceNo
        else { return nil }
        let side = importedCircle.isCombinedAB
            ? "a+b"
            : (importedCircle.circle.spaceNoSub == 1 ? "b" : "a")
        let day = String(localized: "Day \(importedCircle.circle.day ?? 0)")
        return "\(day) · \(block.name)\(String(format: "%02d", spaceNumber))\(side)"
    }

    private var displayName: String {
        guard let name = importedCircle.circle.circleName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return String(localized: "Unnamed circle") }
        return name
    }
}

private struct FollowingImportedCircleArtwork: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource
    let favoriteColor: BookmarkColor?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .aspectRatio(211 / 300, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .overlay { CircleFavoriteMark(color: favoriteColor) }
        .task(id: circle.id) {
            guard let data = await dataSource.getCircleImage(circleId: circle.id),
                  !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}
