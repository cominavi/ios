import Kingfisher
import SwiftUI
import UIKit

struct FollowingImportView: View {
    let dataSource: CirclemsDataSource
    /// The X import runs on the ComiNavi service, so a signed-out person sees
    /// a sign-in prompt instead of a form that fails only after submit.
    let isSignedIn: Bool
    let onSignIn: (() -> Void)?
    @State private var model: FollowingImportModel
    @State private var isShowingImportForm = false
    @Environment(\.appHapticFeedback) private var hapticFeedback

    init(
        dataSource: CirclemsDataSource,
        isSignedIn: Bool = true,
        onSignIn: (() -> Void)? = nil
    ) {
        self.dataSource = dataSource
        self.isSignedIn = isSignedIn
        self.onSignIn = onSignIn
        _model = State(initialValue: FollowingImportModel(dataSource: dataSource))
    }

    var body: some View {
        Group {
            if !isSignedIn {
                signInRequiredSurface
            } else {
                activityContent
            }
        }
        .navigationTitle("X followed circles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { importToolbar }
        .task(id: isSignedIn) {
            guard isSignedIn else { return }
            await model.load()
        }
        .onChange(of: model.importState?.importedAt) { oldValue, newValue in
            guard oldValue != newValue, newValue != nil else { return }
            isShowingImportForm = false
            hapticFeedback?.play(.completion)
        }
        .onChange(of: model.lastBulkFavorite) { _, undo in
            guard let undo else { return }
            hapticFeedback?.play(.completion)
            AppToast.showSuccess(
                String(localized: "Favorited \(undo.circleCount) circles"),
                subtitle: nil
            )
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
    private var activityContent: some View {
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
    }

    private var signInRequiredSurface: some View {
        FocusedActionSurface(symbolName: "person.2.crop.square.stack") {
            Text("Sign in required")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .wrapsFully()

            Text("Sign in to ComiNavi to find the circles that an X account follows in this catalog.")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            if let onSignIn {
                FocusedActionButton(action: onSignIn) {
                    Text("Sign in")
                }
                .padding(.top, Spacing.xxLarge)
                .accessibilityIdentifier("following-import-sign-in")
            }
        }
        .accessibilityIdentifier("following-import-sign-in-required")
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
                .wrapsFully()

            Text("Loading imported circles…")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            CatalogActivityIndicator(accessibilityLabel: "Loading imported circles…")
                .padding(.top, Spacing.xxLarge)
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
                .wrapsFully()

            Text(
                model.progressPreview.phase == .finalizing
                    ? "Preparing matched circles…"
                    : "Scanning up to 5,000 followed accounts…"
            )
            .foregroundStyle(.secondary)
            .wrapsFully()
            .padding(.top, Spacing.medium)

            FollowingImportProgressPreviewView(progress: model.progressPreview)
                .padding(.top, Spacing.xxLarge)
        }
        .accessibilityIdentifier("following-import-progress")
    }

    private var importSurface: some View {
        FocusedActionSurface(symbolName: "person.2.crop.square.stack") {
            Text("Find followed circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .wrapsFully()

            Text("Import an X account to find circles it follows in this catalog.")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack(spacing: Spacing.small) {
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
                .padding(.horizontal, Spacing.large)
                // 52 pt: the height of the large button below it.
                .frame(minHeight: 52)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: .rect(cornerRadius: Radius.control, style: .continuous)
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
            .padding(.top, Spacing.xxLarge)

            Group {
                if let availableAt = model.manualImportAvailableAt {
                    // No-break spaces keep the date and time whole, so a
                    // line never breaks inside "Oct 27" or "3:46 PM".
                    Text(
                        "You can import again after \(NonBreaking.spaces(availableAt.formatted(date: .abbreviated, time: .shortened)))."
                    )
                } else {
                    Text(
                        "You can import once every six hours."
                    )
                }
            }
            .font(.meta)
            .foregroundStyle(.secondary)
            .wrapsFully()
            .padding(.top, Spacing.large)
        }
        .accessibilityIdentifier("following-import-form")
    }

    private var emptyResultsSurface: some View {
        FocusedActionSurface(symbolName: "person.slash") {
            Text("No imported circles")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .wrapsFully()

            Text("Import an X account to find circles it follows in this catalog.")
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.top, Spacing.medium)

            FocusedActionButton(action: showImportForm) {
                LucideLabel("Import", icon: "arrow.down.circle.fill")
            }
            .padding(.top, Spacing.xxLarge)
        }
        .accessibilityIdentifier("following-import-empty")
    }

    private var importedCirclesList: some View {
        List {
            if !model.importedCircles.isEmpty {
                Section("Favorite imported circles") {
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.xSmall) {
                            ForEach(BookmarkColor.selectableColors) { color in
                                Button {
                                    model.selectedColor = color
                                } label: {
                                    // 30 pt drawn swatch inside a 44 pt target.
                                    ColorSwatch(color: color.swiftUIColor, size: 30)
                                        .overlay {
                                            if model.selectedColor == color {
                                                LucideIcon("checkmark", size: IconSize.caption)
                                                    .foregroundStyle(.white)
                                                    .shadow(radius: 1)
                                            }
                                        }
                                        .minimumHitArea()
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(color.displayName)
                                .accessibilityValue(
                                    model.selectedColor == color
                                        ? "Selected"
                                        : "Not selected"
                                )
                                .accessibilityAddTraits(
                                    model.selectedColor == color ? .isSelected : []
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Button(action: model.favoriteAll) {
                        HStack(spacing: Spacing.iconToText) {
                            LucideIcon("star.fill", size: IconSize.row)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                Text("Favorite all imported circles")
                                    .font(.rowTitle)
                                    .foregroundStyle(.primary)
                                Text("Use the selected label color for each circle.")
                                    .font(.meta)
                                    .foregroundStyle(.secondary)
                            }
                            .wrapsFully()
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            ColorSwatch(color: model.selectedColor.swiftUIColor, size: IconSize.row)
                        }
                        .padding(.vertical, Spacing.xSmall)
                    }
                    .disabled(model.activity != .idle)
                    .accessibilityLabel("Favorite all imported circles")
                    .accessibilityValue(
                        Text(
                            "Label color \(String(localized: model.selectedColor.displayName))"
                        )
                    )
                    .accessibilityIdentifier("following-import-favorite-all")

                    if let undo = model.lastBulkFavorite {
                        HStack(spacing: Spacing.medium) {
                            Label {
                                Text("Favorited \(undo.circleCount) circles")
                                    .wrapsFully()
                            } icon: {
                                LucideIcon("checkmark.circle.fill", size: IconSize.inline)
                                    .foregroundStyle(.green)
                            }
                            .font(.rowSubtitle)
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Undo", action: model.undoFavoriteAll)
                                .buttonStyle(.tertiaryAction)
                                .singleLineToken()
                                .disabled(model.activity != .idle)
                                .accessibilityIdentifier("following-import-undo-favorite-all")
                        }
                    }
                }
            }

            Section("Imported circles (\(model.importedPublicCircleCount))") {
                ForEach(model.importedCircles) { importedCircle in
                    let favoriteColor = model.favoriteColor(for: importedCircle)

                    HStack(alignment: .top, spacing: Spacing.small) {
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
                            LucideIcon(favoriteColor == nil ? "star" : "star.fill", size: IconSize.action)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: HitArea.minimum, height: HitArea.minimum)
                                .overlay(alignment: .bottomTrailing) {
                                    if let favoriteColor {
                                        // 9 pt: a dot on the star, smaller than any icon size.
                                        Circle()
                                            .fill(favoriteColor.swiftUIColor)
                                            .frame(width: 9, height: 9)
                                            .overlay {
                                                Circle()
                                                    .stroke(Color(uiColor: .systemBackground), lineWidth: 1)
                                            }
                                    }
                                }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.activity != .idle)
                        .accessibilityLabel(
                            favoriteColor == nil
                                ? "Add to favorites"
                                : "Remove from favorites"
                        )
                        .accessibilityValue(
                            favoriteAccessibilityValue(for: favoriteColor)
                        )
                        .accessibilityHint("Adds or removes this circle from your favorites")
                        .accessibilityAddTraits(favoriteColor == nil ? [] : .isSelected)
                    }
                }
            }
        }
        .readableFormWidth()
    }

    private func favoriteAccessibilityValue(for color: BookmarkColor?) -> String {
        guard let color else { return String(localized: "Not in favorites") }
        return String(
            localized: "In favorites, label color \(String(localized: color.displayName))"
        )
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        if isSignedIn, model.activity == .idle, model.importState != nil {
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

private struct FollowingImportProgressPreviewView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let progress: FollowingImportProgressPreview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxLarge) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.xxLarge) {
                    fetchedMetric
                    matchedMetric
                }

                VStack(alignment: .leading, spacing: Spacing.large) {
                    fetchedMetric
                    matchedMetric
                }
            }

            ProgressView(value: progress.capacityFraction, total: 1)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .scaleEffect(y: 2, anchor: .center)
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.24),
                    value: progress.capacityFraction
                )
                .accessibilityLabel(Text("Import capacity used"))
                .accessibilityValue(
                    Text(
                        progress.capacityFraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                )
        }
    }

    private var fetchedMetric: some View {
        FollowingImportMetric(
            value: progress.fetchedCount,
            label: "Accounts fetched"
        )
    }

    private var matchedMetric: some View {
        FollowingImportMetric(
            value: progress.matchedCircleCount,
            label: "Circles matched"
        )
    }
}

private struct FollowingImportMetric: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let value: Int
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text(value, format: .number.grouping(.automatic))
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .contentTransition(.numericText(value: Double(value)))
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.24),
                    value: value
                )

            Text(label)
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
                .wrapsFully()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value, format: .number.grouping(.automatic)))
    }
}

private struct FollowingImportedCircleRow: View {
    let importedCircle: FollowingImportedCircle
    let dataSource: CirclemsDataSource
    let favoriteColor: BookmarkColor?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            FollowingImportedCircleArtwork(
                circle: importedCircle.circle,
                dataSource: dataSource,
                favoriteColor: favoriteColor
            )
            // 66 pt: a fixed thumbnail width; the circle cut keeps its 211:300 ratio.
            .frame(width: 66)

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text(displayName)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .wrapsFully()

                if let placement = placementLabel {
                    Text(verbatim: placement)
                        .font(.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(importedCircle.sources.prefix(2), id: \.twitterUserID) { source in
                    HStack(spacing: Spacing.small) {
                        KFImage(source.profilePictureURL)
                            .placeholder {
                                Circle().fill(Color(uiColor: .secondarySystemFill))
                            }
                            .targetCache(RemoteImagePipeline.cache(for: .profileImages))
                            .cacheOriginalImage()
                            .diskCacheExpiration(.never)
                            .waitForCache()
                            .resizable()
                            .scaledToFill()
                            // 22 pt: IconSize.action, so the avatar reads as a row glyph.
                            .frame(width: IconSize.action, height: IconSize.action)
                            .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(source.twitterDisplayName)
                                .font(.meta.weight(.medium))
                                .lineLimit(1)
                            // A handle is a value from data: keep both ends.
                            Text("@\(source.twitterUserName)")
                                .font(.meta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
        let space = "\(block.name)\(String(format: "%02d", spaceNumber))\(side)"
        // Each unit stays whole; the line can break only at " · ".
        return "\(NonBreaking.spaces(day)) · \(NonBreaking.unit(space))"
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
        .clipShape(.rect(cornerRadius: Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
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
