import Kingfisher
import SwiftUI
import UIKit

struct CircleDetailView: View {
    let circles: [CirclemsDataSchema.ComiketCircleWC]
    let dataSource: CirclemsDataSource
    let tags: [String]
    let favoriteColorLabelStore: FavoriteColorLabelStore

    @State private var details: CatalogCircleDetails?
    @State private var extensionsByCircleID: [Int: CirclemsDataSchema.ComiketCircleExtend] = [:]
    @State private var circleAddress: ComiketSpaceAddress?
    @State private var circleHallMapName: String?
    @State private var isShowingDataSources = false
    @State private var isOpeningMap = false
    @State private var planModel: CircleUserPlanModel
    @State private var isShowingSharedPlanRequest = false
    @State private var isShowingSignIn = false
    @State private var headerHeight: CGFloat = 0
    @State private var isHeaderScrolledAway = false

    init(
        circle: CirclemsDataSchema.ComiketCircleWC,
        dataSource: CirclemsDataSource,
        tags: [String] = [],
        favoriteColorLabelStore: FavoriteColorLabelStore =
            AppData.favoriteColorLabelStore
    ) {
        circles = [circle]
        self.dataSource = dataSource
        self.tags = tags
        self.favoriteColorLabelStore = favoriteColorLabelStore
        _planModel = State(initialValue: CircleUserPlanModel(
            circle: circle,
            dataSource: dataSource
        ))
    }

    init(
        circles: [CirclemsDataSchema.ComiketCircleWC],
        dataSource: CirclemsDataSource,
        tags: [String] = [],
        favoriteColorLabelStore: FavoriteColorLabelStore =
            AppData.favoriteColorLabelStore
    ) {
        precondition(!circles.isEmpty)
        self.circles = circles.sorted { ($0.spaceNoSub ?? 0) < ($1.spaceNoSub ?? 0) }
        self.dataSource = dataSource
        self.tags = tags
        self.favoriteColorLabelStore = favoriteColorLabelStore
        _planModel = State(initialValue: CircleUserPlanModel(
            circles: circles,
            dataSource: dataSource
        ))
    }

    private var circle: CirclemsDataSchema.ComiketCircleWC { circles[0] }
    private var isCombinedAB: Bool { circles.count == 2 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.sectionGap) {
                CircleDetailHeader(
                    circle: circle,
                    dataSource: dataSource,
                    spaceLabel: spaceLabel,
                    favoriteColor: planModel.selectedColor,
                    address: circleAddress,
                    dayDateText: dayDateText,
                    hallGloss: hallGloss,
                    canOpenMap: circle.updateId != nil,
                    isOpeningMap: isOpeningMap,
                    onOpenMap: openOnMap,
                    externalLinks: externalLinks,
                    xProfile: xProfile
                ) {
                    CircleDetailActionRow(
                        isFavorite: planModel.isFavorite,
                        isFavoriteUnavailable: isFavoriteUnavailable,
                        sharedPlanAvailability: sharedPlanAvailability,
                        onToggleFavorite: { planModel.toggleFavorite() },
                        onAddToSharedPlan: { isShowingSharedPlanRequest = true },
                        onSignIn: { isShowingSignIn = true }
                    )
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    headerHeight = height
                }

                if AppData.profileStore.isIdentityVerified,
                   let currentUserID = AppData.profileStore.profile?.id,
                   let sharedPlanCircleKey
                {
                    CircleDetailSharedPlanSection(
                        store: AppData.sharedPlanStore,
                        currentUserID: currentUserID,
                        circle: sharedPlanCircleKey,
                        dataSource: dataSource,
                        isShowingRequest: $isShowingSharedPlanRequest
                    )
                }

                if !combinedTags.isEmpty {
                    CircleDetailTagsSection(
                        tags: combinedTags,
                        day: circle.day ?? 1,
                        dataSource: dataSource,
                        favoriteColorLabelStore: favoriteColorLabelStore
                    )
                }

                if details?.extensionRecord?.WCId != nil, planModel.isFavorite {
                    CircleUserPlanSection(
                        model: planModel,
                        colorLabelStore: favoriteColorLabelStore
                    )
                }

                if !withdrawalClaims.isEmpty {
                    CircleWithdrawalNotice(claims: withdrawalClaims)
                }

                if !shinagakiPosts.isEmpty {
                    CircleDetailShinagakiSection(posts: shinagakiPosts)
                }

                if hasAboutInformation {
                    CircleDetailSection("About") {
                        VStack(alignment: .leading, spacing: Spacing.medium) {
                            if let bookName = circle.bookName.nonBlank {
                                LabeledContent("Publication", value: bookName)
                            }
                            if let description = circle.description.nonBlank {
                                Text(description)
                                    .font(.body)
                                    .wrapsFully()
                                    .textSelection(.enabled)
                            }
                            if let memo = circle.memo.nonBlank {
                                Text(memo)
                                    .font(.rowSubtitle)
                                    .foregroundStyle(.secondary)
                                    .wrapsFully()
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if isMissingCommunityDetails {
                    InlineBanner("No item list or tags for this circle yet.", icon: "info.circle", tone: .info)
                        .accessibilityIdentifier("circle-detail-empty-state")
                }

                // A page footer link. It uses its own glyph, so it does not
                // repeat the info icon of the notice banner above it.
                Button {
                    isShowingDataSources = true
                } label: {
                    HStack(spacing: Spacing.xSmall) {
                        LucideIcon("database", size: IconSize.caption)
                        Text("Data sources")
                    }
                    .font(.meta)
                }
                .buttonStyle(.tertiaryAction)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Shows where this circle's information came from")
                .accessibilityIdentifier("circle-data-sources-button")
            }
            .readableWidth()
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.vertical, Spacing.xLarge)
        }
        // The header already shows the name and address, so the bar repeats
        // them only once the header has scrolled out of view.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            headerHeight > 0
                && geometry.contentOffset.y + geometry.contentInsets.top > headerHeight
        } action: { _, isScrolledAway in
            isHeaderScrolledAway = isScrolledAway
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .modifier(
            CircleDetailNavigationTitle(
                title: circle.circleName.nonBlank ?? String(localized: "Circle"),
                subtitle: navigationSubtitle,
                isVisible: isHeaderScrolledAway
            )
        )
        // The labeled Favorite button under the header is the one favorite
        // control on this screen, so the bar does not repeat it as a star.
        .navigationBarTitleDisplayMode(.inline)
        // Observed here rather than in the favorite settings section, which
        // only exists after a favorite succeeds, so a failed first toggle
        // still reports why the star reverted.
        .onChange(of: planModel.saveState) { _, state in
            guard case .failed(let message) = state else { return }
            AppToast.showError(
                String(localized: "Could not save circle"),
                subtitle: message
            )
            planModel.dismissSaveError()
        }
        .sheet(isPresented: $isShowingDataSources) {
            CircleDetailDataSourcesSheet(
                details: details,
                officialCatalogLinks: officialCatalogLinks
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSignIn) {
            SignInView()
                .presentationDragIndicator(.visible)
        }
        .onChange(of: AppData.profileStore.isIdentityVerified) { _, isVerified in
            if isVerified {
                isShowingSignIn = false
            }
        }
        .sheet(isPresented: $isShowingSharedPlanRequest) {
            if let key = sharedPlanCircleKey,
               let currentUserID = AppData.profileStore.profile?.id
            {
                SharedPlanCircleQuickAddSheet(
                    store: AppData.sharedPlanStore,
                    currentUserID: currentUserID,
                    circle: key,
                    circleName: circle.circleName.nonBlank ?? String(localized: "Unnamed circle"),
                    penName: circle.penName.nonBlank
                ) { planName in
                    AppToast.showSuccess(
                        String(localized: "Purchase request added"),
                        subtitle: String(localized: "Added to \(planName)")
                    )
                }
            }
        }
        .task(id: circle.id) {
            circleAddress = nil
            circleHallMapName = nil
            await loadCircleAddress()
        }
        .task(id: circle.id) {
            let loadedDetails = await withTaskGroup(
                of: (Int, CatalogCircleDetails).self,
                returning: [Int: CatalogCircleDetails].self
            ) { group in
                for member in circles {
                    group.addTask { [dataSource] in
                        (member.id, await dataSource.getCircleDetails(circleID: member.id))
                    }
                }
                var result: [Int: CatalogCircleDetails] = [:]
                for await (circleID, detail) in group { result[circleID] = detail }
                return result
            }
            let primaryDetails = loadedDetails[circle.id]
            extensionsByCircleID = loadedDetails.compactMapValues(\.extensionRecord)
            let enrichments = loadedDetails.values.compactMap(\.enrichment)
            details = CatalogCircleDetails(
                extensionRecord: primaryDetails?.extensionRecord,
                enrichment: enrichments.isEmpty
                    ? nil
                    : CatalogCircleEnrichment(
                        posts: uniquePosts(enrichments.flatMap(\.posts)),
                        attendanceClaims: enrichments.flatMap(\.attendanceClaims),
                        tags: enrichments.flatMap(\.tags)
                    )
            )
            await planModel.load(publicCircleIDsByCatalogID: loadedDetails.reduce(into: [:]) {
                if let publicCircleID = $1.value.extensionRecord?.WCId {
                    $0[$1.key] = publicCircleID
                }
            })
        }
        .accessibilityIdentifier("circle-detail-screen")
    }

    /// Disables favorite controls only once details have loaded, so the
    /// star stays usable while the public circle ID is still resolving.
    private var isFavoriteUnavailable: Bool {
        details != nil && planModel.isFavoriteUnavailable && !planModel.isFavorite
    }

    private var sharedPlanAvailability: CircleDetailActionRow.SharedPlanAvailability {
        guard AppData.profileStore.isIdentityVerified,
              AppData.profileStore.profile?.id != nil
        else { return .signedOut }
        return sharedPlanCircleKey == nil ? .unavailable : .available
    }

    /// True once details have loaded and the circle has no tags, item list
    /// or About text, so the page explains the gap instead of ending blank.
    private var isMissingCommunityDetails: Bool {
        details != nil
            && combinedTags.isEmpty
            && shinagakiPosts.isEmpty
            && !hasAboutInformation
    }

    private var hasAboutInformation: Bool {
        circle.bookName.nonBlank != nil
            || circle.description.nonBlank != nil
            || circle.memo.nonBlank != nil
    }

    private var sharedPlanCircleKey: SharedPlanCircleKey? {
        guard let publicCircleID = details?.extensionRecord?.WCId else { return nil }
        return SharedPlanCircleKey(comiketNo: circle.comiketNo, wcID: publicCircleID)
    }

    private var shinagakiPosts: [CatalogShinagakiPost] {
        details?.enrichment?.posts ?? []
    }

    private var withdrawalClaims: [CatalogAttendanceClaim] {
        details?.enrichment?.withdrawalClaims ?? []
    }

    private var combinedTags: [String] {
        ExploreModel.canonicalTagLabels(
            details.map { $0.enrichment?.tagLabels ?? [] } ?? tags
        )
    }

    private var spaceLabel: String? {
        guard let blockID = circle.blockId,
              let block = dataSource.comiket.blocks.first(where: {
                  $0.externalBlockId == blockID
              }),
              let spaceNumber = circle.spaceNo
        else { return nil }

        let side = isCombinedAB ? "a+b" : (circle.spaceNoSub == 1 ? "b" : "a")
        return "\(block.name)\(String(format: "%02d", spaceNumber))\(side)"
    }

    /// The calendar date of the circle's day, such as "Sun, Aug 11", shown
    /// next to "Day 1" so attendees do not have to map day numbers to dates.
    private var dayDateText: String? {
        guard let dayIndex = circleAddress?.day ?? circle.day,
              let components = dataSource.comiket.days
                  .first(where: { $0.dayIndex == dayIndex })?.date
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = components.timeZone {
            calendar.timeZone = timeZone
        }
        guard let date = calendar.date(from: components) else { return nil }

        // The app's event-day format ("Sun, Aug 11"), without the year, so
        // the line matches the day pill and stays short.
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// An English gloss such as "West Halls 1–2" under the canonical Japanese
    /// hall text. Japanese readers already read the canonical text, so the
    /// gloss is omitted for them.
    private var hallGloss: String? {
        guard let circleHallMapName,
              Bundle.main.preferredLocalizations.first?.hasPrefix("ja") != true
        else { return nil }
        return CircleHallGloss.text(forMapName: circleHallMapName)
    }

    /// "Day 1 · West あ01a": the same space format as the header card,
    /// Explore, and map search.
    private var navigationSubtitle: String? {
        if let circleAddress {
            return String(localized: "Day \(circleAddress.day) · \(circleAddress.formatted(.short))")
        }
        if let day = circle.day, let spaceLabel {
            return String(localized: "Day \(day) · \(spaceLabel)")
        }
        if let day = circle.day {
            return String(localized: "Day \(day)")
        }
        return spaceLabel
    }

    private var externalLinks: [CircleExternalLink] {
        var seen: Set<String> = []
        return circles.flatMap { member in
            CircleExternalLinkNormalizer.links(
                circle: member,
                extensionRecord: extensionsByCircleID[member.id],
                enrichmentProfileURL: details?.enrichment?.primaryPost?.authorProfileURL
            )
        }.filter { seen.insert($0.id).inserted }
    }

    private var xProfile: CircleXProfile? {
        guard let link = externalLinks.first(where: { $0.kind == .xProfile }) else {
            return nil
        }

        let post = details?.enrichment?.primaryPost
        let handle = post?.authorHandle
            ?? link.preview.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let displayName = post?.authorName.nonBlank
            ?? circle.penName.nonBlank
            ?? circle.circleName.nonBlank
            ?? String(localized: "X profile")

        return CircleXProfile(
            url: link.url,
            displayName: displayName,
            handle: handle,
            avatarURL: post?.authorProfileImageURL
        )
    }

    private var officialCatalogLinks: [CircleExternalLink] {
        CircleExternalLinkNormalizer.links(from: [
            .init(circle.circlems, hint: .circlems),
            .init(extensionsByCircleID[circle.id]?.CirclemsPortalURL, hint: .circlems),
        ])
    }

    private func openOnMap() {
        guard !isOpeningMap,
              let updateID = circle.updateId
        else { return }

        isOpeningMap = true
        Task { @MainActor in
            defer { isOpeningMap = false }
            guard let locations = try? await dataSource.mapCatalog.bookmarkLocations(
                updateIDs: [updateID]
            ),
                let location = locations.first(where: {
                    $0.catalogCircleID == circle.id
                }),
                let sharedLocation = SharedComiketLocation(
                    eventNumber: dataSource.comiket.number,
                    sceneID: .init(day: location.day, mapID: location.mapID),
                    tableID: location.tableID,
                    subspace: location.subspace
                )
            else {
                AppToast.showError(
                    String(localized: "Couldn't find this space on the map"),
                    subtitle: nil
                )
                return
            }

            AppData.sharedLocationInbox.receive(url: sharedLocation.url)
        }
    }

    private func loadCircleAddress() async {
        let updateIDs = circles.compactMap(\.updateId)
        guard let locations = try? await dataSource.mapCatalog.bookmarkLocations(
            updateIDs: updateIDs
        ),
            let location = locations.first(where: { $0.catalogCircleID == circle.id }),
            let blockID = circle.blockId,
            let block = dataSource.comiket.blocks.first(where: { $0.externalBlockId == blockID }),
            // Without a hall the canonical address would be incomplete, so
            // the card keeps showing the plain space label instead.
            let hall = dataSource.comiket.days
                .first(where: { $0.dayIndex == location.day })?
                .halls.first(where: { $0.externalMapId == location.mapID })
        else { return }
        circleHallMapName = hall.mapName
        circleAddress = ComiketSpaceAddress(
            day: location.day,
            hallName: location.resolvedHallName(in: dataSource.comiket) ?? hall.name,
            blockName: block.name,
            spaceNumber: location.tableID.spaceNumber,
            subspace: isCombinedAB ? nil : location.subspace,
            isCombinedAB: isCombinedAB
        )
    }

    private func uniquePosts(_ posts: [CatalogShinagakiPost]) -> [CatalogShinagakiPost] {
        var seen: Set<String> = []
        return posts.filter { seen.insert($0.id).inserted }
    }
}

private struct CircleXProfile {
    let url: URL
    let displayName: String
    let handle: String
    let avatarURL: URL?
}

private struct CircleXProfileRow: View {
    let profile: CircleXProfile
    /// Leads with the handle when the display name only repeats a name that
    /// is already visible, such as the pen name in the header.
    var prefersHandle = false

    @ScaledMetric(relativeTo: .subheadline) private var avatarSize = 40.0

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.small) {
            // The avatar's X badge names the platform, so the text does not
            // repeat "X" under the handle.
            CircleXProfileAvatar(url: profile.avatarURL, size: avatarSize)

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                if prefersHandle {
                    Text(verbatim: "@\(profile.handle)")
                        .font(.control)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    DimmedCircleDisplayName(displayName: profile.displayName)
                        .font(.control)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(verbatim: "@\(profile.handle)")
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            LucideIcon("chevron.forward", size: IconSize.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("X profile, \(profile.displayName), @\(profile.handle)")
        )
    }
}

private struct DimmedCircleDisplayName: View {
    let displayName: String

    var body: some View {
        if let atIndex = displayName.firstIndex(of: "@") {
            let leading = String(displayName[..<atIndex]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trailing = String(displayName[atIndex...]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if leading.isEmpty {
                Text(verbatim: trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: leading)
                    .foregroundStyle(.primary)
                + Text(verbatim: " \(trailing)")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(verbatim: displayName)
                .foregroundStyle(.primary)
        }
    }
}

private struct CircleXProfileAvatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        KFImage(url?.highResolutionXProfileImageURL)
            .placeholder {
                LucideIcon("person.circle.fill", size: Double(size * 0.62))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemFill))
            }
            .targetCache(RemoteImagePipeline.cache(for: .profileImages))
            .cacheOriginalImage()
            .diskCacheExpiration(.never)
            .waitForCache()
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                Circle()
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                // The badge scales with the avatar and stays inside its
                // bounds, so it never reaches the text beside the avatar.
                IconifyBrandIcon("x", size: 9)
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .background(.background, in: .circle)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.hairline, lineWidth: 0.5)
                    }
            }
            .accessibilityHidden(true)
    }
}

private extension URL {
    var highResolutionXProfileImageURL: URL {
        guard host?.lowercased() == "pbs.twimg.com",
              path.contains("/profile_images/")
        else { return self }

        let thumbnailMarkers = ["_normal.", "_bigger.", "_mini."]
        guard let marker = thumbnailMarkers.first(where: path.contains) else {
            return self
        }

        var components = URLComponents(
            url: self,
            resolvingAgainstBaseURL: false
        )
        components?.path = path.replacingOccurrences(
            of: marker,
            with: "_400x400."
        )
        return components?.url ?? self
    }
}

private struct CircleDetailHeader<Actions: View>: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource
    let spaceLabel: String?
    let favoriteColor: BookmarkColor?
    let address: ComiketSpaceAddress?
    let dayDateText: String?
    let hallGloss: String?
    let canOpenMap: Bool
    let isOpeningMap: Bool
    let onOpenMap: () -> Void
    let externalLinks: [CircleExternalLink]
    let xProfile: CircleXProfile?
    let actions: Actions

    @State private var image: UIImage?
    @State private var didFailLoadingImage = false
    @State private var isShowingLightbox = false
    @State private var copiedLocation = false
    @State private var copyGeneration = 0
    @ScaledMetric(relativeTo: .title) private var compactArtworkWidth = 154.0
    @ScaledMetric(relativeTo: .title) private var regularArtworkWidth = 230.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appHapticFeedback) private var hapticFeedback

    init(
        circle: CirclemsDataSchema.ComiketCircleWC,
        dataSource: CirclemsDataSource,
        spaceLabel: String?,
        favoriteColor: BookmarkColor?,
        address: ComiketSpaceAddress?,
        dayDateText: String?,
        hallGloss: String?,
        canOpenMap: Bool,
        isOpeningMap: Bool,
        onOpenMap: @escaping () -> Void,
        externalLinks: [CircleExternalLink],
        xProfile: CircleXProfile?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.circle = circle
        self.dataSource = dataSource
        self.spaceLabel = spaceLabel
        self.favoriteColor = favoriteColor
        self.address = address
        self.dayDateText = dayDateText
        self.hallGloss = hallGloss
        self.canOpenMap = canOpenMap
        self.isOpeningMap = isOpeningMap
        self.onOpenMap = onOpenMap
        self.externalLinks = externalLinks
        self.xProfile = xProfile
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if isStacked {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    artwork(width: min(artworkWidth, 220))
                    identityDetails
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.large) {
                    artwork(width: artworkWidth)

                    VStack(alignment: .leading, spacing: Spacing.large) {
                        identityDetails
                        // On iPad the actions fill the identity column, so
                        // it balances the taller cut beside it.
                        if showsActionsInIdentityColumn {
                            actions
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let spaceLabel {
                locationRow(spaceLabel: spaceLabel)
            }

            if !showsActionsInIdentityColumn {
                actions
            }
        }
        .task(id: circle.id) {
            image = nil
            didFailLoadingImage = false
            let data = await dataSource.getCircleImage(circleId: circle.id)
            image = await Task.detached(priority: .userInitiated) {
                data.flatMap(UIImage.init(data:))
            }.value
            didFailLoadingImage = image == nil
        }
        .fullScreenCover(isPresented: $isShowingLightbox) {
            if let image {
                ShinagakiLightbox(
                    image: image,
                    accessibilityLabel: String(localized: "Circle cut for \(displayName)")
                )
                .dismissesOnDownwardDrag()
                .presentationBackground(.clear)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-detail-header")
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Stacks the cut above the name once the identity column beside it
    /// would fall under about 200 pt, where the X handle starts to truncate.
    private var isStacked: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }
        return !isRegularWidth && dynamicTypeSize >= .xxLarge
    }

    private var showsActionsInIdentityColumn: Bool {
        isRegularWidth && !isStacked
    }

    /// iPad gets a larger cut. The iPhone cut stops growing at 1.1× so the
    /// identity column keeps room for the X handle at larger text sizes.
    private var artworkWidth: CGFloat {
        isRegularWidth ? regularArtworkWidth : min(compactArtworkWidth, 154 * 1.1)
    }

    private var isJapaneseLocale: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ja") == true
    }

    private func artwork(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return Group {
            if let image {
                Button {
                    isShowingLightbox = true
                } label: {
                    FittedArtworkImage(image: Image(uiImage: image))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Circle cut for \(displayName)")
                .accessibilityHint("Opens the image viewer")
                .accessibilityIdentifier("circle-cover-lightbox-button")
            } else {
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        if didFailLoadingImage {
                            LucideIcon("photo.badge.exclamationmark", size: IconSize.hero)
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(180 / 256, contentMode: .fit)
        .frame(width: width)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.hairline, lineWidth: 0.5)
        }
        .overlay {
            CircleFavoriteMark(color: favoriteColor)
        }
    }

    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // The circle name is the screen's hero title, one step above the
            // card and row titles.
            Text(displayName)
                .font(.title2.weight(.bold))
                .wrapsFully()
                .textSelection(.enabled)

            if let penName = circle.penName.nonBlank {
                Text(penName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                    .textSelection(.enabled)
            }

            if let xProfile {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                Link(destination: xProfile.url) {
                    CircleXProfileRow(
                        profile: xProfile,
                        prefersHandle: xProfile.displayName == circle.penName.nonBlank
                    )
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.small)
                    .frame(minHeight: HitArea.minimum)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                    .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in your browser")
                .accessibilityIdentifier("circle-x-profile-row")
            }

            if !otherExternalLinks.isEmpty {
                CircleDetailExternalLinksRow(links: otherExternalLinks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var otherExternalLinks: [CircleExternalLink] {
        externalLinks.filter { $0.kind != .xProfile }
    }

    /// The location card. The pin and the copy button align with the space
    /// code line, and "Show on map" sits under the text column.
    private func locationRow(spaceLabel: String) -> some View {
        HStack(alignment: .spaceCodeLine, spacing: Spacing.iconToText) {
            LucideIcon("mappin.and.ellipse", size: IconSize.row)
                .foregroundStyle(Color.accentColor)
                .alignmentGuide(.spaceCodeLine) { $0[VerticalAlignment.center] }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                locationText(spaceLabel: spaceLabel)

                if canOpenMap {
                    mapButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let address {
                copyButton(address)
                    .alignmentGuide(.spaceCodeLine) { $0[VerticalAlignment.center] }
            }
        }
        .surface(.card)
        .accessibilityElement(children: .contain)
    }

    /// The space in the app's one format ("West あ01a"), then the day, the
    /// English hall gloss, and the Japanese address that staff and signs use.
    @ViewBuilder
    private func locationText(spaceLabel: String) -> some View {
        let spaceText = address?.formatted(.short) ?? spaceLabel
        Text(nonBreaking: spaceText)
            .font(.spaceCode)
            .foregroundStyle(.primary)
            .alignmentGuide(.spaceCodeLine) { $0[VerticalAlignment.center] }
            .accessibilityLabel(Text(verbatim: spaceText))
            .accessibilityIdentifier("circle-location-venue")

        if let day = address?.day ?? circle.day {
            Group {
                // The date is one unit; the line can break only at " · ".
                if let dayDateText {
                    Text("Day \(day) · \(NonBreaking.spaces(dayDateText))")
                } else {
                    Text("Day \(day)")
                }
            }
            .font(.meta)
            .foregroundStyle(.secondary)
            .wrapsFully()
            .accessibilityIdentifier("circle-location-day")
        }

        if let hallGloss {
            Text(verbatim: NonBreaking.spaces(hallGloss))
                .font(.meta)
                .foregroundStyle(.secondary)
                .wrapsFully()
        }

        if let address {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                // Japanese readers already read the address as written, so
                // only other locales need the caption that explains it.
                if !isJapaneseLocale {
                    Text("Japanese address (for staff and signs)")
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .wrapsFully()
                }
                Text(verbatim: Self.japaneseAddressDisplayText(address))
                    .font(isJapaneseLocale ? Font.meta : Font.rowSubtitle)
                    .foregroundStyle(isJapaneseLocale ? Color.secondary : Color.primary)
                    .wrapsFully()
                    .accessibilityLabel(Text(verbatim: address.venueLocationText))
            }
            .padding(.top, Spacing.xSmall)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("circle-location-japanese-address")
        }
    }

    /// "西12ホール あ01a" with each part kept whole, so a line breaks only
    /// between the hall and the space code.
    private static func japaneseAddressDisplayText(_ address: ComiketSpaceAddress) -> String {
        address.venueLocationText
            .split(separator: " ")
            .map { NonBreaking.unit(String($0)) }
            .joined(separator: " ")
    }

    private var mapButton: some View {
        Button(action: onOpenMap) {
            if isOpeningMap {
                HStack(spacing: Spacing.xSmall) {
                    Text("Show on map")
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                // The chevron is in the text run, so at accessibility sizes
                // it wraps with "map" instead of taking its own column.
                TrailingGlyphText(
                    Text("Show on map"),
                    glyph: "chevron.forward",
                    glyphStyle: .primary
                )
            }
        }
        .buttonStyle(.tertiaryAction)
        .disabled(isOpeningMap)
        .accessibilityHint("Shows this circle on the map")
        .accessibilityIdentifier("circle-location-map-button")
    }

    private func copyButton(_ address: ComiketSpaceAddress) -> some View {
        Button {
            copy(address)
        } label: {
            LucideIcon(copiedLocation ? "checkmark" : "doc.on.doc", size: IconSize.row)
                .foregroundStyle(copiedLocation ? Color.green : Color.accentColor)
                .minimumHitArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy circle location")
        .accessibilityValue(copiedLocation ? Text("Copied") : Text(verbatim: ""))
        .accessibilityHint("Copies the Japanese address for staff and signs")
        .accessibilityIdentifier("circle-location-copy-button")
        .animation(.default, value: copiedLocation)
    }

    private func copy(_ address: ComiketSpaceAddress) {
        UIPasteboard.general.string = address.canonicalText
        copiedLocation = true
        copyGeneration += 1
        hapticFeedback?.play(.copyConfirmation)
        let currentGeneration = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard copyGeneration == currentGeneration else { return }
            copiedLocation = false
        }
    }

    private var displayName: String {
        circle.circleName.nonBlank ?? String(localized: "Unnamed circle")
    }
}

private extension VerticalAlignment {
    /// The center of the space-code line in the location card. The pin and
    /// the copy button align to it instead of to the whole card.
    enum SpaceCodeLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.top]
        }
    }

    static let spaceCodeLine = VerticalAlignment(SpaceCodeLine.self)
}

/// The favorite and shared plan actions. "Show on map" is in the location
/// card, so this row holds the other two actions and stays visible even when
/// the circle has no enrichment.
private struct CircleDetailActionRow: View {
    enum SharedPlanAvailability {
        case available
        case unavailable
        case signedOut
    }

    let isFavorite: Bool
    let isFavoriteUnavailable: Bool
    let sharedPlanAvailability: SharedPlanAvailability
    let onToggleFavorite: () -> Void
    let onAddToSharedPlan: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // Equal widths side by side, or a full-width column when a title
            // would wrap in its half.
            AdaptiveButtonRow(spacing: Spacing.small) {
                favoriteButton
                sharedPlanButton
            }

            if isFavoriteUnavailable {
                Text("Favorites aren't available for this circle.")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-detail-actions")
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            LucideLabel(
                isFavorite ? "Favorited" : "Favorite",
                icon: isFavorite ? "star.fill" : "star"
            )
        }
        .buttonStyle(ActionButtonStyle(role: isFavorite ? .primary : .secondary))
        .disabled(isFavoriteUnavailable)
        .accessibilityHint("Adds or removes this circle from your favorites")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
        .accessibilityIdentifier("circle-favorite-action")
    }

    private var sharedPlanButton: some View {
        Button {
            switch sharedPlanAvailability {
            case .available:
                onAddToSharedPlan()
            case .signedOut:
                onSignIn()
            case .unavailable:
                break
            }
        } label: {
            // Signed out, the title itself says that sign-in comes first, so
            // no caption under both buttons has to explain one of them.
            if sharedPlanAvailability == .signedOut {
                LucideLabel("Sign in to add to plan", icon: "cart.fill")
            } else {
                LucideLabel("Add to shared plan", icon: "cart.fill")
            }
        }
        .buttonStyle(.secondaryAction)
        .disabled(sharedPlanAvailability == .unavailable)
        .accessibilityHint(Text(sharedPlanHint))
        .accessibilityIdentifier("circle-shared-plan-action")
    }

    private var sharedPlanHint: LocalizedStringKey {
        sharedPlanAvailability == .signedOut
            ? "Opens sign-in"
            : "Adds a purchase request for this circle to a shared plan"
    }
}

/// The circle's other links (pixiv, website, Circle.ms) as one-line chips.
private struct CircleDetailExternalLinksRow: View {
    let links: [CircleExternalLink]

    var body: some View {
        // Chips wrap instead of scrolling sideways: a horizontal scroller in
        // the narrow identity column clipped the last chip at the edge. The
        // chip style already pads each 32 pt capsule to a 44 pt target, so
        // the rows need no extra line spacing.
        CircleTagFlowLayout(spacing: Spacing.small, lineSpacing: 0) {
            ForEach(links) { link in
                Link(destination: link.url) {
                    HStack(spacing: Spacing.xSmall) {
                        CircleExternalLinkIcon(kind: link.kind)
                        Text(link.title)
                    }
                }
                .buttonStyle(.chip)
                .accessibilityLabel(Text(link.title))
                .accessibilityValue(Text(verbatim: link.preview))
                .accessibilityHint("Opens in your browser")
                .accessibilityIdentifier(link.accessibilityIdentifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-external-links")
    }

    private struct CircleExternalLinkIcon: View {
        let kind: CircleExternalLink.Kind

        var body: some View {
            Group {
                switch kind {
                case .xProfile:
                    IconifyBrandIcon("x", size: IconSize.inline)
                case .pixiv:
                    IconifyBrandIcon("pixiv", size: IconSize.inline)
                case .website:
                    LucideIcon("globe", size: IconSize.inline)
                case .circlems:
                    // A catalog record, not a group of people.
                    LucideIcon("doc.richtext", size: IconSize.inline)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

#if DEBUG
    struct CircleDetailExternalLinksRowTestHost: View {
        let links: [CircleExternalLink]

        var body: some View {
            CircleDetailExternalLinksRow(links: links)
        }
    }
#endif

private struct CircleUserPlanSection: View {
    let model: CircleUserPlanModel
    let colorLabelStore: FavoriteColorLabelStore

    @FocusState private var isNoteFocused: Bool

    var body: some View {
        @Bindable var model = model

        CircleDetailSection("Favorite settings") {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.iconToText) {
                    LucideIcon("star.fill", size: IconSize.row)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Saved to favorites")
                            .font(.rowTitle)
                        Text("Choose a label color for this favorite.")
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    .wrapsFully()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // The badge keeps its size; the text beside it wraps.
                    if let selectedColor = model.selectedColor {
                        FavoriteColorLabelBadge(
                            color: selectedColor,
                            label: colorLabelStore.customLabels[selectedColor]
                        )
                        .layoutPriority(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("circle-favorite-status")

                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Label color")
                        .font(.control)

                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.small) {
                            ForEach(BookmarkColor.selectableColors) { color in
                                CirclePlanColorButton(
                                    color: color,
                                    label: colorLabelStore.customLabels[color],
                                    isSelected: model.selectedColor == color,
                                    onSelect: { model.selectColor(color) }
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Private note")
                        .font(.control)

                    TextEditor(text: $model.memo)
                        .focused($isNoteFocused)
                        .frame(minHeight: 92)
                        .padding(Spacing.small)
                        .scrollContentBackground(.hidden)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: .rect(cornerRadius: Radius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(
                                    isNoteFocused ? Color.accentColor : Color.hairline,
                                    lineWidth: isNoteFocused ? 1.5 : 0.5
                                )
                        }
                        .onChange(of: model.memo) {
                            model.memoDidChange()
                        }
                        .onChange(of: isNoteFocused) { _, focused in
                            if !focused {
                                model.flushMemo()
                            }
                        }
                        .accessibilityIdentifier("circle-private-note")
                }
            }
        }
        .accessibilityIdentifier("circle-user-plan-section")
        .onDisappear {
            model.flushMemo()
        }
    }
}

private struct CirclePlanColorButton: View {
    let color: BookmarkColor
    let label: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        FavoriteColorLabelSelectionButton(
            color: color,
            label: label,
            isSelected: isSelected,
            accessibilityIdentifier: "circle-favorite-color-\(color.rawValue)",
            action: onSelect
        )
    }
}

private struct CircleDetailNavigationTitle: ViewModifier {
    let title: String
    let subtitle: String?
    let isVisible: Bool

    func body(content: Content) -> some View {
        // `navigationTitle` keeps the back menu and the VoiceOver screen
        // title; the principal item controls what the bar shows. Using the
        // principal item on every OS also avoids the extra subtitle row that
        // `navigationSubtitle` adds on iPad.
        content
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CircleDetailPrincipalTitle(
                        title: title,
                        subtitle: subtitle
                    )
                    .opacity(isVisible ? 1 : 0)
                    .accessibilityHidden(!isVisible)
                    .animation(.easeOut(duration: 0.15), value: isVisible)
                }
            }
    }
}

private struct CircleDetailPrincipalTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            // Bar chrome: one line each, truncated at the tail.
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CircleWithdrawalNotice: View {
    let claims: [CatalogAttendanceClaim]

    var body: some View {
        if let claim = claims.first {
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    LucideLabel("Reported not attending", icon: "person.crop.circle.badge.xmark")
                        .font(.rowTitle)
                        .foregroundStyle(.red)
                        .wrapsFully()
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    StatusBadge(Text(claim.confidence.title), tone: .warning)
                }

                Text("A public X post says this allocated circle will not attend. Its official catalog placement remains shown.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .wrapsFully()

                Link(destination: claim.postURL) {
                    LucideLabel("View attendance evidence on X", icon: "arrow.up.right")
                }
                .buttonStyle(.tertiaryAction)
                .accessibilityHint("Opens the original public post")
            }
            .padding(Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A destructive-status card: the red tint replaces the grouped fill.
            .background(Color.red.opacity(0.08), in: shape)
            .overlay {
                shape.strokeBorder(Color.red.opacity(0.24), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("circle-withdrawal-notice")
        }
    }
}

private struct CircleDetailDataSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let details: CatalogCircleDetails?
    let officialCatalogLinks: [CircleExternalLink]

    var body: some View {
        NavigationStack {
            List {
                officialCatalogSection

                if !xEvidence.isEmpty {
                    publicXEvidenceSection
                }

            }
            .navigationTitle("Data sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("circle-data-sources-sheet")
    }

    private var officialCatalogSection: some View {
        Section("Official catalog") {
            LabeledContent("Source") {
                Text("Circle.ms Web Catalog")
            }

            ForEach(officialCatalogLinks) { link in
                Link(destination: link.url) {
                    LucideLabel("Open official Circle.ms record", icon: "arrow.up.right")
                }
                .accessibilityHint("Opens the official catalog record")
            }

        }
    }

    private var publicXEvidenceSection: some View {
        Section("Public X evidence") {
            ForEach(xEvidence) { evidence in
                Link(destination: evidence.url) {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text(evidence.title)
                            .foregroundStyle(.primary)
                        Text(verbatim: "@\(evidence.authorHandle)")
                            .font(.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityHint("Opens the original public post")
            }
        }
    }

    private var xEvidence: [CatalogXEvidence] {
        let postEvidence = (details?.enrichment?.posts ?? []).map {
            CatalogXEvidence(
                id: "shinagaki:\($0.id)",
                title: "Item list post",
                url: $0.postURL,
                authorHandle: $0.authorHandle
            )
        }
        let attendanceEvidence = (details?.enrichment?.attendanceClaims ?? []).map {
            CatalogXEvidence(
                id: "attendance:\($0.id)",
                title: $0.status == .withdrawn ? "Withdrawal report" : "Attendance report",
                url: $0.postURL,
                authorHandle: $0.authorHandle
            )
        }

        var seenURLs: Set<URL> = []
        return (postEvidence + attendanceEvidence).filter {
            seenURLs.insert($0.url).inserted
        }
    }
}

private struct CatalogXEvidence: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let url: URL
    let authorHandle: String
}

private struct CircleDetailSection<Content: View>: View {
    let title: LocalizedStringResource
    let contentPadding: CGFloat
    let content: Content

    /// - Parameter contentPadding: The card's inner padding. Pass 0 when the
    ///   rows draw their own insets.
    init(
        _ title: LocalizedStringResource,
        contentPadding: CGFloat = Spacing.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(title)
                .font(.sectionTitle)
                .wrapsFully()
                .accessibilityAddTraits(.isHeader)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.card, padding: contentPadding)
        }
    }
}

private struct CircleDetailSharedPlanSection: View {
    let store: SharedPlanStore
    let currentUserID: String
    let circle: SharedPlanCircleKey
    let dataSource: CirclemsDataSource
    @Binding var isShowingRequest: Bool

    @State private var model = SharedPlanCirclePurchasePreviewModel()

    var body: some View {
        CircleDetailSection("Shared Plans", contentPadding: 0) {
            if model.groups.isEmpty {
                emptyPurchaseButton
            } else {
                VStack(spacing: 0) {
                    ForEach(model.groups) { group in
                        CircleDetailSharedPlanPurchaseGroup(
                            store: store,
                            group: group,
                            currentUserID: currentUserID,
                            circle: circle,
                            dataSource: dataSource
                        )
                    }

                    Divider()
                        .padding(.leading, Spacing.cardPadding)

                    Button {
                        isShowingRequest = true
                    } label: {
                        HStack(spacing: Spacing.iconToText) {
                            LucideIcon("plus", size: IconSize.row)
                                .foregroundStyle(.accent)
                                .accessibilityHidden(true)
                            Text("Add purchase request")
                                .font(.rowTitle)
                                .wrapsFully()
                                .layoutPriority(1)
                            Spacer(minLength: Spacing.small)
                            LucideIcon("chevron-right", size: IconSize.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(Spacing.cardPadding)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("circle-add-another-shared-plan-request")
                }
            }
        }
        .task {
            await store.load()
        }
        .task(id: observationID) {
            await model.run(
                circle: circle,
                planIDs: activePlanIDs,
                using: store
            )
        }
    }

    private var activePlanIDs: [String] {
        store.activePlans(comiketNo: circle.comiketNo).map(\.id)
    }

    private var observationID: String {
        "\(circle.id):\(activePlanIDs.joined(separator: ","))"
    }

    private var emptyPurchaseButton: some View {
        Button {
            isShowingRequest = true
        } label: {
            HStack(spacing: Spacing.iconToText) {
                LucideIcon("shopping-cart", size: IconSize.row)
                    .foregroundStyle(.accent)
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("Add a purchase request")
                        .font(.rowTitle)
                    Text("Choose a plan, name the item, and set how many you need.")
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
                .wrapsFully()
                .layoutPriority(1)
                Spacer(minLength: Spacing.small)
                LucideIcon("chevron-right", size: IconSize.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.cardPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("circle-add-shared-plan-request")
    }
}

private struct CircleDetailSharedPlanPurchaseGroup: View {
    let store: SharedPlanStore
    let group: SharedPlanCirclePurchaseGroup
    let currentUserID: String
    let circle: SharedPlanCircleKey
    let dataSource: CirclemsDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.planName)
                .font(.meta.weight(.semibold))
                .foregroundStyle(.secondary)
                .wrapsFully()
                .padding(.horizontal, Spacing.cardPadding)
                .padding(.top, Spacing.medium)

            ForEach(group.purchases) { purchase in
                VStack(spacing: 0) {
                    if purchase.id != group.purchases.first?.id {
                        Divider()
                            .padding(.leading, Spacing.cardPadding)
                    }

                    NavigationLink {
                        SharedPlanEditorScreen(
                            store: store,
                            planID: group.planID,
                            currentUserID: currentUserID,
                            catalogDataSource: dataSource,
                            initialPublicCircleID: circle.wcID
                        )
                    } label: {
                        SharedPlanPurchaseSummaryRow(
                            need: purchase.need,
                            hasConflict: purchase.hasConflict
                        )
                        .padding(Spacing.cardPadding)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "circle-shared-plan-purchase-\(purchase.need.id.uuidString.lowercased())"
                    )
                }
            }
        }
    }
}

private struct CircleDetailTagsSection: View {
    let tags: [String]
    let day: Int
    let dataSource: CirclemsDataSource
    let favoriteColorLabelStore: FavoriteColorLabelStore

    var body: some View {
        CircleDetailSection("Tags") {
            // The chips pad themselves to a 44 pt target, so rows need no
            // extra line spacing.
            CircleTagFlowLayout(spacing: Spacing.small, lineSpacing: 0) {
                ForEach(tags, id: \.self) { tag in
                    NavigationLink {
                        ExploreTagPage(
                            tag: tag,
                            day: day,
                            dataSource: dataSource,
                            favoriteColorLabelStore: favoriteColorLabelStore
                        )
                    } label: {
                        // A tag is a data value: one line, truncated in the
                        // middle when it is wider than the card. The accent
                        // tint keeps the chips visible on the card fill.
                        HStack(spacing: Spacing.xSmall) {
                            LucideIcon("tag", size: IconSize.caption)
                            Text(verbatim: tag)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.control)
                        .padding(.horizontal, Spacing.medium)
                        // 6 pt and 32 pt match the chip style's capsule.
                        .padding(.vertical, 6)
                        .frame(minHeight: 32)
                        .background(Color.accentColor.opacity(0.12), in: .capsule)
                        .padding(.vertical, (HitArea.minimum - 32) / 2)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows circles with this tag")
                }
            }
        }
        .accessibilityIdentifier("circle-tags-section")
    }
}

/// Wraps tag chips into rows. A chip wider than the container is measured
/// against the container width, so its label truncates instead of pushing
/// past the card edge.
private struct CircleTagFlowLayout: Layout {
    /// The gap between chips in a row, and between rows by default.
    let spacing: CGFloat
    /// The gap between rows when it differs from `spacing`, for example 0
    /// for chips that already pad themselves to a 44 pt target.
    var lineSpacing: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(
        width: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + (lineSpacing ?? spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, width), height: y + rowHeight), frames)
    }
}

private struct CircleDetailShinagakiSection: View {
    let posts: [CatalogShinagakiPost]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            SectionHeader("Item list", subtitle: "The circle's items and prices")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

            ShinagakiMatchNotice()

            VStack(alignment: .leading, spacing: Spacing.large) {
                ForEach(posts) { post in
                    ShinagakiPostCard(post: post)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-shinagaki-section")
    }
}

private struct ShinagakiMatchNotice: View {
    var body: some View {
        InlineBanner(
            "Automatically matched from public X posts. Check the confidence and space before relying on it.",
            icon: "exclamationmark.triangle.fill",
            tone: .warning
        )
        .accessibilityIdentifier("shinagaki-match-notice")
    }
}

private struct ShinagakiPostCard: View {
    let post: CatalogShinagakiPost

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .top, spacing: Spacing.xSmall) {
                Link(destination: post.authorProfileURL ?? post.postURL) {
                    CircleXProfileRow(
                        profile: CircleXProfile(
                            url: post.authorProfileURL ?? post.postURL,
                            displayName: post.authorName.nonBlank
                                ?? "@\(post.authorHandle)",
                            handle: post.authorHandle,
                            avatarURL: post.authorProfileImageURL
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in your browser")
                .frame(maxWidth: .infinity, alignment: .leading)

                ShinagakiConfidenceIndicator(post: post)
            }

            if !displayableMedia.isEmpty {
                ShinagakiMediaGallery(
                    postID: post.id,
                    media: displayableMedia,
                    accessibilityLabel: String(
                        localized: "Item list image by \(post.authorHandle)"
                    )
                )
            }

            ExpandableShinagakiText(
                text: post.text,
                postID: post.id
            )

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.card)
        .accessibilityElement(children: .contain)
    }

    /// The post date and the link side by side, or stacked when they do not
    /// both fit on one line (Japanese, large text sizes).
    @ViewBuilder
    private var footer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                postDate
                openLink
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                    postDate
                    Spacer(minLength: Spacing.small)
                    openLink
                }
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    postDate
                    openLink
                }
            }
        }
    }

    @ViewBuilder
    private var postDate: some View {
        if let createdAt = post.createdAt {
            // ViewThatFits picks the row only when the date fits on one line
            // at its ideal width; in the column the date may wrap.
            Text(createdAt, format: CatalogDateFormatting.full(for: createdAt))
                .font(.meta)
                .foregroundStyle(.secondary)
                .wrapsFully()
        }
    }

    private var openLink: some View {
        Link(destination: post.postURL) {
            LucideLabel("Open item list on X", icon: "arrow.up.right")
        }
        .buttonStyle(.tertiaryAction)
        .accessibilityHint("Opens the original public post")
        .accessibilityIdentifier("circle-shinagaki-post-\(post.id)")
    }

    private var displayableMedia: [CatalogShinagakiMedia] {
        post.media.filter { media in
            media.kind != .video || media.previewURL != nil
        }
    }
}

private struct ExpandableShinagakiText: View {
    let text: String
    let postID: String

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(isExpanded || !requiresExpansion ? nil : 4)
                .textSelection(.enabled)
                .accessibilityIdentifier("shinagaki-post-text-\(postID)")

            if requiresExpansion {
                Button(isExpanded ? "Show less" : "Show more") {
                    toggleExpansion()
                }
                .buttonStyle(.tertiaryAction)
                .frame(minWidth: HitArea.minimum, alignment: .leading)
                .accessibilityIdentifier("shinagaki-post-expand-\(postID)")
            }
        }
    }

    private var requiresExpansion: Bool {
        text.count > 120 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }

    private func toggleExpansion() {
        if accessibilityReduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct ShinagakiConfidenceIndicator: View {
    let post: CatalogShinagakiPost

    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            VStack(spacing: Spacing.xxSmall) {
                confidenceLight(for: post.postConfidence)
                confidenceLight(for: post.placementConfidence)
                confidenceLight(for: overallConfidence)
            }
            // 6 pt: a compact tile around the three 4 pt lights.
            .padding(6)
            .background(
                Color(uiColor: .tertiarySystemFill),
                in: .rect(cornerRadius: Radius.small, style: .continuous)
            )
            .minimumHitArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Match confidence")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows what each confidence indicator means")
        .accessibilityIdentifier("shinagaki-confidence-indicator-\(post.id)")
        .sheet(isPresented: $isShowingDetails) {
            ShinagakiConfidenceSheet(
                postConfidence: post.postConfidence,
                placementConfidence: post.placementConfidence,
                overallConfidence: overallConfidence
            )
            .presentationDetents([.medium])
        }
    }

    private var overallConfidence: CatalogConfidence {
        [post.postConfidence, post.placementConfidence]
            .min { $0.indicatorRank < $1.indicatorRank } ?? .unmatched
    }

    private var accessibilityValue: Text {
        let postLabel = String(localized: "Post confidence")
        let postValue = String(localized: post.postConfidence.title)
        let placementLabel = String(localized: "Placement confidence")
        let placementValue = String(localized: post.placementConfidence.title)
        let overallLabel = String(localized: "Overall confidence")
        let overallValue = String(localized: overallConfidence.title)
        let value = [
            "\(postLabel): \(postValue)",
            "\(placementLabel): \(placementValue)",
            "\(overallLabel): \(overallValue)",
        ]
        .joined(separator: ", ")

        return Text(verbatim: value)
    }

    private func confidenceLight(for confidence: CatalogConfidence) -> some View {
        Capsule()
            .fill(confidence.indicatorColor)
            .frame(width: 14, height: 4)
            .accessibilityHidden(true)
    }
}

private struct ShinagakiConfidenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let postConfidence: CatalogConfidence
    let placementConfidence: CatalogConfidence
    let overallConfidence: CatalogConfidence

    var body: some View {
        NavigationStack {
            List {
                Section {
                    confidenceRow(
                        title: "Post confidence",
                        confidence: postConfidence,
                        explanation: "How strongly the public X post appears to be an item list post."
                    )
                    confidenceRow(
                        title: "Placement confidence",
                        confidence: placementConfidence,
                        explanation: "How strongly the post is linked to this circle and its catalog space placement."
                    )
                    confidenceRow(
                        title: "Overall confidence",
                        confidence: overallConfidence,
                        explanation: "The lower of the two confidence levels above, so a weak post or placement match lowers the overall result."
                    )
                } footer: {
                    Text("These are automatic estimates from public information. Check the original post and space before relying on them.")
                }
            }
            .navigationTitle("Match confidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("shinagaki-confidence-sheet")
    }

    private func confidenceRow(
        title: LocalizedStringResource,
        confidence: CatalogConfidence,
        explanation: LocalizedStringResource
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            Capsule()
                .fill(confidence.indicatorColor)
                .frame(width: 6, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                    Text(title)
                        .font(.rowTitle)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(confidence.title)
                        .font(.control)
                        .foregroundStyle(confidence.indicatorColor)
                        .singleLineToken()
                }

                Text(explanation)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}

private extension CatalogConfidence {
    var indicatorColor: Color {
        switch self {
        case .high:
            .green
        case .medium:
            .orange
        case .low:
            .red
        case .unmatched:
            .gray
        }
    }

    var indicatorRank: Int {
        switch self {
        case .high:
            3
        case .medium:
            2
        case .low:
            1
        case .unmatched:
            0
        }
    }
}

private struct ShinagakiRemoteImage: View {
    let page: ShinagakiLightboxPage
    let imageLoader: @MainActor (URL) async -> UIImage?
    let onOpen: (ShinagakiLightboxPage, UIImage) -> Void

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Button {
                    onOpen(page, image)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        FittedArtworkImage(image: Image(uiImage: image))

                        LucideIcon("arrow.up.left.and.arrow.down.right", size: IconSize.caption)
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.regularMaterial, in: .circle)
                            .padding(Spacing.small)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.accessibilityLabel)
                .accessibilityHint("Opens the image viewer")
                .accessibilityIdentifier("shinagaki-image-preview-\(page.id)")
            } else if didFail {
                LucideContentUnavailableView(
                    "Image unavailable",
                    icon: "photo.badge.exclamationmark"
                )
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemFill))
                    ProgressView()
                }
            }
        }
        .background(Color(uiColor: .secondarySystemFill))
        .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        }
        .aspectRatio(
            ShinagakiArtworkLayout.previewAspectRatio(for: image?.size ?? .zero),
            contentMode: .fit
        )
        .task(id: page.displayURL) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        didFail = false

        guard let decodedImage = await page.loadImage(using: imageLoader),
              !Task.isCancelled
        else {
            if !Task.isCancelled {
                didFail = true
            }
            return
        }
        image = decodedImage
    }
}

private struct ShinagakiMediaGallery: View {
    let postID: String
    let media: [CatalogShinagakiMedia]
    let accessibilityLabel: String
    private let imageLoader: @MainActor (URL) async -> UIImage?

    @State private var presentation: ShinagakiLightboxPresentation?

    init(
        postID: String,
        media: [CatalogShinagakiMedia],
        accessibilityLabel: String,
        imageLoader: @escaping @MainActor (URL) async -> UIImage? = { url in
            await RemoteImagePipeline.image(for: url, category: .shinagaki)
        }
    ) {
        self.postID = postID
        self.media = media
        self.accessibilityLabel = accessibilityLabel
        self.imageLoader = imageLoader
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Spacing.medium) {
                ForEach(pages) { page in
                    ShinagakiRemoteImage(
                        page: page,
                        imageLoader: imageLoader,
                        onOpen: open
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("shinagaki-media-gallery")
        .fullScreenCover(item: $presentation) { presentation in
            ShinagakiLightbox(presentation: presentation)
                .dismissesOnDownwardDrag()
                .presentationBackground(.clear)
        }
    }

    private var pages: [ShinagakiLightboxPage] {
        ShinagakiLightboxPage.pages(
            postID: postID,
            media: media,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func open(
        page: ShinagakiLightboxPage,
        image: UIImage
    ) {
        let lightboxPages = pages.map { candidate in
            candidate.id == page.id
                ? candidate.withInitialImage(image)
                : candidate
        }
        presentation = ShinagakiLightboxPresentation(
            pages: lightboxPages,
            selectedPageID: page.id
        )
    }
}

#if DEBUG
    struct ShinagakiMediaGalleryTestHost: View {
        let postID: String
        let media: [CatalogShinagakiMedia]
        let accessibilityLabel: String
        let imageLoader: @MainActor (URL) async -> UIImage?

        var body: some View {
            ShinagakiMediaGallery(
                postID: postID,
                media: media,
                accessibilityLabel: accessibilityLabel,
                imageLoader: imageLoader
            )
        }
    }
#endif

/// Builds an English gloss for a Big Sight hall from its catalog map name,
/// for example "W12" becomes "West Halls 1–2" and "E7" becomes "East Hall 7".
private enum CircleHallGloss {
    static func text(forMapName mapName: String) -> String? {
        guard let direction = mapName.uppercased().first else { return nil }
        let numbers = mapName.dropFirst().compactMap(\.wholeNumberValue)
        guard let first = numbers.first, let last = numbers.last else { return nil }

        let isSingleHall = first == last
        let range = isSingleHall ? "\(first)" : "\(first)–\(last)"
        switch (direction, isSingleHall) {
        case ("E", true): return String(localized: "East Hall \(range)")
        case ("E", false): return String(localized: "East Halls \(range)")
        case ("W", true): return String(localized: "West Hall \(range)")
        case ("W", false): return String(localized: "West Halls \(range)")
        case ("S", true): return String(localized: "South Hall \(range)")
        case ("S", false): return String(localized: "South Halls \(range)")
        default: return nil
        }
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
