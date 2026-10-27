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
            LazyVStack(alignment: .leading, spacing: 24) {
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
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    headerHeight = height
                }

                CircleDetailActionRow(
                    isFavorite: planModel.isFavorite,
                    isFavoriteUnavailable: isFavoriteUnavailable,
                    sharedPlanAvailability: sharedPlanAvailability,
                    onToggleFavorite: { planModel.toggleFavorite() },
                    onAddToSharedPlan: { isShowingSharedPlanRequest = true },
                    onSignIn: { isShowingSignIn = true }
                )

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
                        VStack(alignment: .leading, spacing: 12) {
                            if let bookName = circle.bookName.nonBlank {
                                LabeledContent("Publication", value: bookName)
                            }
                            if let description = circle.description.nonBlank {
                                Text(description)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            if let memo = circle.memo.nonBlank {
                                Text(memo)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if isMissingCommunityDetails {
                    LucideLabel("No item list or tags for this circle yet.", icon: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 16)
                        )
                        .accessibilityIdentifier("circle-detail-empty-state")
                }

                Button {
                    isShowingDataSources = true
                } label: {
                    LucideLabel("Data sources", icon: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows where this circle's information came from")
                .accessibilityIdentifier("circle-data-sources-button")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    planModel.toggleFavorite()
                } label: {
                    LucideIcon(planModel.isFavorite ? "star.fill" : "star", size: 21)
                        .foregroundStyle(planModel.isFavorite ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(
                    planModel.isFavorite ? "Remove from favorites" : "Add to favorites"
                )
                .accessibilityValue(planModel.isFavorite ? "In favorites" : "Not in favorites")
                .accessibilityHint("Adds or removes this circle from your favorites")
                .accessibilityAddTraits(planModel.isFavorite ? .isSelected : [])
                .disabled(isFavoriteUnavailable)
                .accessibilityIdentifier("circle-favorite-button")
            }
        }
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

        var style = CatalogDateFormatting.abbreviated(for: date, calendar: calendar)
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

    private var navigationSubtitle: String? {
        if let circleAddress {
            return circleAddress.navigationSubtitle
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
                    String(localized: "Couldn't find this booth on the map"),
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
            hallName: hall.name,
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
    var avatarSize: CGFloat = 40
    /// Leads with the handle when the display name only repeats a name that
    /// is already visible, such as the pen name in the header.
    var prefersHandle = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CircleXProfileAvatar(url: profile.avatarURL, size: avatarSize)

            VStack(alignment: .leading, spacing: 1) {
                if prefersHandle {
                    Text(verbatim: "@\(profile.handle)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(verbatim: "X")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DimmedCircleDisplayName(displayName: profile.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(verbatim: "@\(profile.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            LucideIcon("chevron.forward", size: 14)
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
                    .stroke(Color(uiColor: .separator).opacity(0.24), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                IconifyBrandIcon("x", size: 9)
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
                    .background(.background, in: .circle)
                    .overlay {
                        Circle()
                            .stroke(
                                Color(uiColor: .separator).opacity(0.32),
                                lineWidth: 0.5
                            )
                    }
                    .offset(x: 2, y: 2)
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

private struct CircleDetailHeader: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    artwork(width: min(artworkWidth, 220))
                    identityDetails
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    artwork(width: artworkWidth)
                    identityDetails
                }
            }

            if let spaceLabel {
                locationRow(spaceLabel: spaceLabel)
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

    /// iPad gets a larger cut; the identity column is capped so the X row
    /// and link chips do not stretch across the readable-width column.
    private var artworkWidth: CGFloat {
        isRegularWidth ? regularArtworkWidth : compactArtworkWidth
    }

    private func artwork(width: CGFloat) -> some View {
        Group {
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
                            LucideIcon("photo.badge.exclamationmark")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(180 / 256, contentMode: .fit)
        .frame(width: width)
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 0.5)
        }
        .overlay {
            CircleFavoriteMark(color: favoriteColor)
        }
    }

    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)

            if let penName = circle.penName.nonBlank {
                Text(penName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let xProfile {
                Link(destination: xProfile.url) {
                    CircleXProfileRow(
                        profile: xProfile,
                        prefersHandle: xProfile.displayName == circle.penName.nonBlank
                    )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 13)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(
                                    Color(uiColor: .separator).opacity(0.24),
                                    lineWidth: 0.5
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in your browser")
                .accessibilityIdentifier("circle-x-profile-row")
            }

            if !otherExternalLinks.isEmpty {
                CircleDetailExternalLinksRow(links: otherExternalLinks)
            }
        }
        .frame(maxWidth: isRegularWidth ? 380 : .infinity, alignment: .leading)
    }

    private var otherExternalLinks: [CircleExternalLink] {
        externalLinks.filter { $0.kind != .xProfile }
    }

    private func locationRow(spaceLabel: String) -> some View {
        HStack(spacing: 4) {
            if canOpenMap {
                Button(action: onOpenMap) {
                    locationSummary(spaceLabel: spaceLabel, showsMapAffordance: true)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isOpeningMap)
                .accessibilityHint("Shows this circle on the map")
                .accessibilityIdentifier("circle-location-map-button")
            } else {
                locationSummary(spaceLabel: spaceLabel, showsMapAffordance: false)
                    .accessibilityElement(children: .combine)
            }

            if let address {
                Button {
                    copy(address)
                } label: {
                    LucideIcon(copiedLocation ? "checkmark" : "doc.on.doc", size: 20)
                        .foregroundStyle(copiedLocation ? .green : Color.accentColor)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy circle location")
                .accessibilityValue(
                    copiedLocation ? Text("Copied") : Text(verbatim: "")
                )
                .accessibilityHint("Copies \(address.canonicalText)")
                .accessibilityIdentifier("circle-location-copy-button")
                .animation(.default, value: copiedLocation)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.24), lineWidth: 0.5)
        }
    }

    /// The day, canonical venue text and optional map affordance. The venue
    /// stays in `.primary`; the accent is reserved for the pin and the
    /// "Show on map" affordance so the text keeps full contrast.
    /// Puts "Show on map" beside the address when the day line fits on one
    /// line, and under it otherwise, so the date never wraps in a narrow
    /// column.
    @ViewBuilder
    private func locationSummary(
        spaceLabel: String,
        showsMapAffordance: Bool
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || !showsMapAffordance {
                VStack(alignment: .leading, spacing: 8) {
                    locationText(spaceLabel: spaceLabel)
                    if showsMapAffordance { mapAffordance }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        locationText(spaceLabel: spaceLabel)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        mapAffordance
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        locationText(spaceLabel: spaceLabel)
                        mapAffordance
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private func locationText(spaceLabel: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LucideIcon("mappin.and.ellipse", size: 20)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                if let day = address?.day ?? circle.day {
                    Group {
                        if let dayDateText {
                            Text("Day \(day) · \(dayDateText)")
                        } else {
                            Text("Day \(day)")
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("circle-location-day")
                }

                Text(verbatim: address?.venueLocationText ?? spaceLabel)
                    .font(.headline.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("circle-location-venue")

                if let hallGloss {
                    Text(verbatim: hallGloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var mapAffordance: some View {
        Group {
            if isOpeningMap {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Text("Show on map")
                    LucideIcon("chevron.forward", size: 14)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(minHeight: 44)
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

/// The persistent primary actions under the header. "Show on map" is the
/// location card above, so this row holds the favorite and shared plan
/// actions and stays visible even when the circle has no enrichment.
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
        VStack(alignment: .leading, spacing: 8) {
            // Equal widths side by side, or a full-width column when
            // "Add to shared plan" would wrap in its half.
            AdaptiveButtonRow {
                favoriteButton
                sharedPlanButton
            }

            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            LucideLabel("Add to shared plan", icon: "cart.fill")
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

    private var caption: LocalizedStringKey? {
        if sharedPlanAvailability == .signedOut {
            return "Sign in to add requests"
        }
        if isFavoriteUnavailable {
            return "Favorites aren't available for this circle."
        }
        return nil
    }
}

/// A labeled action button. The prominent variant uses the lime fill behind
/// dark text; the plain variant matches the grouped cards on the page.
private struct CircleDetailExternalLinksRow: View {
    let links: [CircleExternalLink]

    var body: some View {
        // Chips wrap instead of scrolling sideways: a horizontal scroller in
        // the narrow identity column clipped the last chip at the edge.
        CircleTagFlowLayout(spacing: 8) {
            ForEach(links) { link in
                Link(destination: link.url) {
                    HStack(spacing: 6) {
                        CircleExternalLinkIcon(kind: link.kind)
                        Text(link.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: .capsule
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                Color(uiColor: .separator).opacity(0.24),
                                lineWidth: 0.5
                            )
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(link.title))
                .accessibilityValue(Text(verbatim: link.preview))
                .accessibilityHint("Opens in your browser")
                .accessibilityIdentifier(link.accessibilityIdentifier)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-external-links")
    }

    private struct CircleExternalLinkIcon: View {
        let kind: CircleExternalLink.Kind

        var body: some View {
            Group {
                switch kind {
                case .xProfile:
                    IconifyBrandIcon("x", size: 15)
                case .pixiv:
                    IconifyBrandIcon("pixiv", size: 17)
                case .website:
                    LucideIcon("globe", size: 16)
                case .circlems:
                    // A catalog record, not a group of people.
                    LucideIcon("doc.richtext", size: 16)
                }
            }
            .foregroundStyle(.primary)
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    LucideIcon("star.fill", size: 20)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor.opacity(0.12), in: .circle)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saved to favorites")
                            .font(.body.weight(.semibold))
                        Text("Choose a label color for this favorite.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let selectedColor = model.selectedColor {
                        FavoriteColorLabelBadge(
                            color: selectedColor,
                            label: colorLabelStore.customLabels[selectedColor]
                        )
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("circle-favorite-status")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Label color")
                        .font(.subheadline.weight(.semibold))

                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Private note")
                        .font(.subheadline.weight(.semibold))

                    TextEditor(text: $model.memo)
                        .focused($isNoteFocused)
                        .frame(minHeight: 92)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: .rect(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    isNoteFocused
                                        ? Color.accentColor
                                        : Color(uiColor: .separator).opacity(0.3),
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LucideLabel("Reported not attending", icon: "person.crop.circle.badge.xmark")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Spacer(minLength: 8)

                    Text(claim.confidence.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.12), in: .capsule)
                }

                Text("A public X post says this allocated circle will not attend. Its official catalog placement remains shown.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Link(destination: claim.postURL) {
                    LucideLabel("View attendance evidence on X", icon: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityHint("Opens the original public post")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.red.opacity(0.24), lineWidth: 0.5)
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(evidence.title)
                            .foregroundStyle(.primary)
                        Text(verbatim: "@\(evidence.authorHandle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
    let contentInsets: EdgeInsets
    let content: Content

    init(
        _ title: LocalizedStringResource,
        contentInsets: EdgeInsets = EdgeInsets(
            top: 16,
            leading: 16,
            bottom: 16,
            trailing: 16
        ),
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.contentInsets = contentInsets
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))

            content
                .padding(contentInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            Color(uiColor: .separator).opacity(0.22),
                            lineWidth: 0.5
                        )
                }
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
        CircleDetailSection("Shared Plans", contentInsets: EdgeInsets()) {
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
                        .padding(.leading, 16)

                    Button {
                        isShowingRequest = true
                    } label: {
                        HStack(spacing: 12) {
                            LucideIcon("plus", size: 20)
                                .foregroundStyle(.accent)
                                .accessibilityHidden(true)
                            Text("Add purchase request")
                                .font(.body.weight(.semibold))
                            Spacer(minLength: 8)
                            LucideIcon("chevron-right", size: 17)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(16)
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
            HStack(spacing: 12) {
                LucideIcon("shopping-cart", size: 22)
                    .foregroundStyle(.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a purchase request")
                        .font(.body.weight(.semibold))
                    Text("Choose a plan, name the item, and set how many you need.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LucideIcon("chevron-right", size: 17)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ForEach(group.purchases) { purchase in
                VStack(spacing: 0) {
                    if purchase.id != group.purchases.first?.id {
                        Divider()
                            .padding(.leading, 16)
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
                        .padding(16)
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
            CircleTagFlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    NavigationLink {
                        ExploreTagPage(
                            tag: tag,
                            day: day,
                            dataSource: dataSource,
                            favoriteColorLabelStore: favoriteColorLabelStore
                        )
                    } label: {
                        LucideLabel(verbatim: tag, icon: "tag")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Color.accentColor.opacity(0.12), in: .capsule)
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
    let spacing: CGFloat

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
                y += rowHeight + spacing
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Item list")
                    .font(.title3.weight(.bold))

                Text("Shinagaki: the circle's items and prices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ShinagakiMatchNotice()

            VStack(alignment: .leading, spacing: 16) {
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
        HStack(alignment: .top, spacing: 8) {
            LucideIcon("exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Automatically matched from public X posts. Check the confidence and booth before relying on it.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shinagaki-match-notice")
    }
}

private struct ShinagakiPostCard: View {
    let post: CatalogShinagakiPost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
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

                Spacer(minLength: 8)

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

            HStack(spacing: 12) {
                if let createdAt = post.createdAt {
                    Text(
                        createdAt,
                        format: CatalogDateFormatting.full(for: createdAt)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Link(destination: post.postURL) {
                    LucideLabel("Open item list on X", icon: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityHint("Opens the original public post")
                .accessibilityIdentifier("circle-shinagaki-post-\(post.id)")
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(uiColor: .separator).opacity(0.24), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
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
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
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
            VStack(spacing: 2) {
                confidenceLight(for: post.postConfidence)
                confidenceLight(for: post.placementConfidence)
                confidenceLight(for: overallConfidence)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
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
                        explanation: "How strongly the post is linked to this circle and its catalog booth placement."
                    )
                    confidenceRow(
                        title: "Overall confidence",
                        confidence: overallConfidence,
                        explanation: "The lower of the two confidence levels above, so a weak post or placement match lowers the overall result."
                    )
                } footer: {
                    Text("These are automatic estimates from public information. Check the original post and booth before relying on them.")
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
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(confidence.indicatorColor)
                .frame(width: 6, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)

                    Spacer(minLength: 12)

                    Text(confidence.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(confidence.indicatorColor)
                }

                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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

                        LucideIcon("arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.regularMaterial, in: .circle)
                            .padding(8)
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
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
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
            LazyHStack(alignment: .top, spacing: 12) {
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
