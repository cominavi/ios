import SwiftUI
import UIKit

struct CircleDetailView: View {
    let circles: [CirclemsDataSchema.ComiketCircleWC]
    let dataSource: CirclemsDataSource
    let tags: [String]

    @State private var details: CatalogCircleDetails?
    @State private var extensionsByCircleID: [Int: CirclemsDataSchema.ComiketCircleExtend] = [:]
    @State private var circleAddress: ComiketSpaceAddress?
    @State private var isShowingDataSources = false
    @State private var isOpeningMap = false
    @State private var planModel: CircleUserPlanModel
    @State private var isShowingSharedPlanRequest = false

    init(
        circle: CirclemsDataSchema.ComiketCircleWC,
        dataSource: CirclemsDataSource,
        tags: [String] = []
    ) {
        circles = [circle]
        self.dataSource = dataSource
        self.tags = tags
        _planModel = State(initialValue: CircleUserPlanModel(
            circle: circle,
            dataSource: dataSource
        ))
    }

    init(
        circles: [CirclemsDataSchema.ComiketCircleWC],
        dataSource: CirclemsDataSource,
        tags: [String] = []
    ) {
        precondition(!circles.isEmpty)
        self.circles = circles.sorted { ($0.spaceNoSub ?? 0) < ($1.spaceNoSub ?? 0) }
        self.dataSource = dataSource
        self.tags = tags
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
                    isOpeningMap: isOpeningMap,
                    onOpenMap: openOnMap,
                    externalLinks: externalLinks,
                    xProfile: xProfile
                )

                if details?.extensionRecord?.WCId != nil {
                    sharedPlanSection
                }

                if !combinedTags.isEmpty {
                    CircleDetailTagsSection(
                        tags: combinedTags,
                        day: circle.day ?? 1,
                        dataSource: dataSource
                    )
                }

                if details?.extensionRecord?.WCId != nil, planModel.isFavorite {
                    CircleUserPlanSection(model: planModel)
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

                Button {
                    isShowingDataSources = true
                } label: {
                    LucideLabel("Sources", icon: "info.circle")
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
        .background(Color(uiColor: .systemGroupedBackground))
        .modifier(
            CircleDetailNavigationTitle(
                title: circle.circleName.nonBlank ?? String(localized: "Circle"),
                subtitle: navigationSubtitle
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
                .accessibilityIdentifier("circle-favorite-button")
            }
        }
        .sheet(isPresented: $isShowingDataSources) {
            CircleDetailDataSourcesSheet(
                details: details,
                officialCatalogLinks: officialCatalogLinks
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                        attendanceClaims: enrichments.flatMap(\.attendanceClaims)
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

    private var hasAboutInformation: Bool {
        circle.bookName.nonBlank != nil
            || circle.description.nonBlank != nil
            || circle.memo.nonBlank != nil
    }

    @ViewBuilder
    private var sharedPlanSection: some View {
        if AppData.profileStore.isIdentityVerified,
           AppData.profileStore.profile?.id != nil
        {
            CircleDetailSection("Shared Plans", contentInsets: EdgeInsets()) {
                Button {
                    isShowingSharedPlanRequest = true
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
        ExploreModel.mergedTagLabels(
            remoteTags: tags,
            enrichmentTags: details?.enrichment?.tagLabels ?? []
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
            else { return }

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
            let block = dataSource.comiket.blocks.first(where: { $0.externalBlockId == blockID })
        else { return }
        let hallName = dataSource.comiket.days
            .first(where: { $0.dayIndex == location.day })?
            .halls.first(where: { $0.externalMapId == location.mapID })?
            .name ?? "会場"
        circleAddress = ComiketSpaceAddress(
            day: location.day,
            hallName: hallName,
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

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CircleXProfileAvatar(url: profile.avatarURL, size: avatarSize)

            VStack(alignment: .leading, spacing: 1) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            LucideIcon("chevron.forward", size: 14)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: profile.displayName))
        .accessibilityValue(Text(verbatim: "@\(profile.handle)"))
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
        AsyncImage(url: url?.highResolutionXProfileImageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                LucideIcon("person.circle.fill", size: Double(size * 0.62))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemFill))
            }
        }
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
    let isOpeningMap: Bool
    let onOpenMap: () -> Void
    let externalLinks: [CircleExternalLink]
    let xProfile: CircleXProfile?

    @State private var image: UIImage?
    @State private var didFailLoadingImage = false
    @State private var isShowingLightbox = false
    @State private var copiedLocation = false
    @State private var copyGeneration = 0
    @ScaledMetric(relativeTo: .title) private var artworkWidth = 154.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        .sheet(isPresented: $isShowingLightbox) {
            if let image {
                ShinagakiLightbox(
                    image: image,
                    accessibilityLabel: String(localized: "Circle cover for \(displayName)")
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-detail-header")
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
                .accessibilityLabel("Circle cover for \(displayName)")
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
                    CircleXProfileRow(profile: xProfile)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(otherExternalLinks) { link in
                            Link(destination: link.url) {
                                CircleExternalLinkIcon(kind: link.kind)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Color(uiColor: .secondarySystemGroupedBackground),
                                        in: Circle()
                                    )
                                    .overlay {
                                        Circle()
                                            .stroke(
                                                Color(uiColor: .separator).opacity(0.24),
                                                lineWidth: 0.5
                                            )
                                    }
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(link.title))
                            .accessibilityValue(Text(verbatim: link.preview))
                            .accessibilityHint("Opens in your browser")
                            .accessibilityIdentifier(link.accessibilityIdentifier)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("circle-external-links")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var otherExternalLinks: [CircleExternalLink] {
        externalLinks.filter { $0.kind != .xProfile }
    }

    private struct CircleExternalLinkIcon: View {
        let kind: CircleExternalLink.Kind

        var body: some View {
            Group {
                switch kind {
                case .xProfile:
                    IconifyBrandIcon("x", size: 19)
                case .pixiv:
                    IconifyBrandIcon("pixiv", size: 21)
                case .website:
                    LucideIcon("globe", size: 20)
                case .circlems:
                    LucideIcon("person.2.crop.square.stack", size: 20)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        }
    }

    private func locationRow(spaceLabel: String) -> some View {
        HStack(spacing: 8) {
            Button(action: onOpenMap) {
                HStack(alignment: .top, spacing: 10) {
                    LucideIcon("mappin.and.ellipse", size: 20)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        if let day = address?.day ?? circle.day {
                            Text("Day \(day)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("circle-location-day")
                        }

                        Text(verbatim: address?.venueLocationText ?? spaceLabel)
                            .font(.headline.monospaced().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("circle-location-venue")
                    }

                    if isOpeningMap {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isOpeningMap)
            .accessibilityHint("Shows this circle on the map")
            .accessibilityIdentifier("circle-location-map-button")

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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
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

private struct CircleUserPlanSection: View {
    let model: CircleUserPlanModel

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
                        Circle()
                            .fill(selectedColor.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle()
                                    .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                            }
                            .accessibilityLabel(Text(selectedColor.displayName))
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
        .onChange(of: model.saveState) { _, state in
            guard case .failed(let message) = state else { return }
            AppToast.showError(
                String(localized: "Could not save circle"),
                subtitle: message
            )
            model.dismissSaveError()
        }
        .onDisappear {
            model.flushMemo()
        }
    }
}

private struct CirclePlanColorButton: View {
    let color: BookmarkColor
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        LucideIcon("checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? Color.primary : Color.clear,
                            lineWidth: 2
                        )
                        .padding(-3)
                }
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.displayName))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("circle-favorite-color-\(color.rawValue)")
    }
}

private struct CircleDetailNavigationTitle: ViewModifier {
    let title: String
    let subtitle: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let subtitle {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        } else if let subtitle {
            content
                .navigationTitle(String())
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        CircleDetailPrincipalTitle(
                            title: title,
                            subtitle: subtitle
                        )
                    }
                }
        } else {
            content.navigationTitle(title)
        }
    }
}

private struct CircleDetailPrincipalTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                title: "Shinagaki post",
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

private struct CircleDetailTagsSection: View {
    let tags: [String]
    let day: Int
    let dataSource: CirclemsDataSource

    var body: some View {
        CircleDetailSection("Tags") {
            CircleTagFlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    NavigationLink {
                        ExploreTagPage(tag: tag, day: day, dataSource: dataSource)
                    } label: {
                        LucideLabel(verbatim: tag, icon: "tag")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
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
        for (index, point) in arrangement(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, width), height: y + rowHeight), points)
    }
}

private struct CircleDetailShinagakiSection: View {
    let posts: [CatalogShinagakiPost]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shinagaki")
                .font(.title3.weight(.bold))

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
                    media: displayableMedia,
                    accessibilityLabel: String(
                        localized: "Shinagaki image by \(post.authorHandle)"
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
                    LucideLabel("Open shinagaki on X", icon: "arrow.up.right")
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
                        explanation: "How strongly the public X post appears to be a shinagaki post."
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
    let media: CatalogShinagakiMedia
    let accessibilityLabel: String

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var isShowingLightbox = false

    var body: some View {
        Group {
            if let image {
                Button {
                    isShowingLightbox = true
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
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Opens the image viewer")
                .accessibilityIdentifier("shinagaki-image-preview")
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
        .task(id: media.displayURL) {
            await loadImage()
        }
        .sheet(isPresented: $isShowingLightbox) {
            if let image {
                ShinagakiLightbox(
                    image: image,
                    accessibilityLabel: accessibilityLabel
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
            }
        }
    }

    private func loadImage() async {
        image = nil
        didFail = false

        var request = URLRequest(url: media.displayURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()

            if let response = response as? HTTPURLResponse {
                guard (200..<300).contains(response.statusCode) else {
                    didFail = true
                    return
                }
            }

            guard let decodedImage = UIImage(data: data) else {
                didFail = true
                return
            }
            image = decodedImage
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}

private struct ShinagakiMediaGallery: View {
    let media: [CatalogShinagakiMedia]
    let accessibilityLabel: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(media, id: \.self) { item in
                ShinagakiRemoteImage(
                    media: item,
                    accessibilityLabel: accessibilityLabel
                )
                .frame(maxWidth: .infinity)
            }
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
