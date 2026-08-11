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
    @State private var sharedPlanConfirmation: String?

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
                    onOpenMap: openOnMap
                )

                if !combinedTags.isEmpty {
                    CircleDetailTagsSection(
                        tags: combinedTags,
                        day: circle.day ?? 1,
                        dataSource: dataSource
                    )
                }

                if details?.extensionRecord?.WCId != nil {
                    CircleUserPlanSection(model: planModel)
                    sharedPlanSection
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

                if !externalLinks.isEmpty {
                    CircleDetailSection(
                        "Links",
                        contentInsets: EdgeInsets()
                    ) {
                        VStack(spacing: 0) {
                            ForEach(externalLinks) { item in
                                Link(destination: item.url) {
                                    HStack(spacing: 12) {
                                        LucideIcon(item.systemImage)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 24)
                                            .accessibilityHidden(true)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)

                                            Text(item.preview)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 12)

                                        LucideIcon("arrow.up.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.tertiary)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .frame(minHeight: 56)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(CircleListRowButtonStyle())
                                .accessibilityHint("Opens in your browser")
                                .accessibilityIdentifier(item.accessibilityIdentifier)

                                if item.id != externalLinks.last?.id {
                                    Divider()
                                        .padding(.leading, 52)
                                }
                            }
                        }
                        .clipShape(.rect(cornerRadius: 16))
                    }
                }
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
                    isShowingDataSources = true
                } label: {
                    LucideLabel("Data sources", icon: "info.circle")
                }
                .accessibilityHint("Shows where this circle's information came from")
                .accessibilityIdentifier("circle-data-sources-button")
            }
        }
        .sheet(isPresented: $isShowingDataSources) {
            CircleDetailDataSourcesSheet(
                circle: circle,
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
                    circleName: circle.circleName.nonBlank ?? String(localized: "Unnamed circle")
                ) { planName in
                    sharedPlanConfirmation = String(localized: "Added to \(planName)")
                }
            }
        }
        .alert(
            "Purchase request added",
            isPresented: Binding(
                get: { sharedPlanConfirmation != nil },
                set: { if !$0 { sharedPlanConfirmation = nil } }
            )
        ) {
            Button("OK") { sharedPlanConfirmation = nil }
        } message: {
            Text(sharedPlanConfirmation ?? "")
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
            await loadCircleAddress()
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
            CircleDetailSection("Shared Plans") {
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
            return String(
                localized: "Day \(circleAddress.day) · \(circleAddress.venueLocationText)"
            )
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

private struct CircleDetailHeader: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource
    let spaceLabel: String?
    let favoriteColor: BookmarkColor?
    let address: ComiketSpaceAddress?
    let isOpeningMap: Bool
    let onOpenMap: () -> Void

    @State private var image: UIImage?
    @State private var didFailLoadingImage = false
    @State private var isShowingLightbox = false
    @State private var copiedLocation = false
    @State private var copyFeedback = 0
    @ScaledMetric(relativeTo: .title) private var artworkWidth = 154.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .sensoryFeedback(.success, trigger: copyFeedback)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("circle-detail-header")
    }

    private func artwork(width: CGFloat) -> some View {
        Group {
            if let image {
                Button {
                    isShowingLightbox = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityValue(copiedLocation ? "Copied" : "")
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
        copyFeedback += 1
        let currentFeedback = copyFeedback
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard copyFeedback == currentFeedback else { return }
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

        CircleDetailSection("Your plan") {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: model.toggleFavorite) {
                    LucideLabel(
                        resource:
                        model.isFavorite
                            ? LocalizedStringResource("Saved circle")
                            : LocalizedStringResource("Save circle"),
                        icon: model.isFavorite ? "star.fill" : "star"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.selectedColor?.swiftUIColor ?? Color.accentColor)
                .accessibilityIdentifier("circle-favorite-button")

                if model.isFavorite {
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
                .navigationTitle("")
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

    let circle: CirclemsDataSchema.ComiketCircleWC
    let details: CatalogCircleDetails?
    let officialCatalogLinks: [CircleExternalLink]

    var body: some View {
        NavigationStack {
            List {
                officialCatalogSection

                if !xEvidence.isEmpty {
                    publicXEvidenceSection
                }

                if let enrichment = details?.enrichment,
                   !enrichment.posts.isEmpty || !enrichment.attendanceClaims.isEmpty {
                    automatedMatchingSection(enrichment: enrichment)
                }

                if let tags = details?.enrichment?.tags, !tags.isEmpty {
                    tagProvenanceSection(tags: tags)
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

            LabeledContent("Catalog record") {
                Text(verbatim: "C\(circle.comiketNo) · \(circle.id)")
                    .monospacedDigit()
            }

            ForEach(officialCatalogLinks) { link in
                Link(destination: link.url) {
                    LucideLabel("Open official Circle.ms record", icon: "arrow.up.right")
                }
                .accessibilityHint("Opens the official catalog record")
            }

            Text("The official catalog allocation is preserved even when later public attendance evidence says the circle withdrew.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    private func automatedMatchingSection(
        enrichment: CatalogCircleEnrichment
    ) -> some View {
        Section("Automated matching") {
            ForEach(enrichment.posts) { post in
                CatalogPostDecisionSourceRow(post: post)
            }

            ForEach(enrichment.attendanceClaims) { claim in
                CatalogAttendanceDecisionSourceRow(claim: claim)
            }
        }
    }

    private func tagProvenanceSection(
        tags: [CatalogEnrichmentTag]
    ) -> some View {
        Section("Tag provenance") {
            ForEach(tags) { tag in
                CatalogTagSourceRow(tag: tag)
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

private struct CatalogPostDecisionSourceRow: View {
    let post: CatalogShinagakiPost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shinagaki match")
                .font(.headline)

            if let policyID = post.matchingPolicyID {
                LabeledContent("Matching policy", value: policyID)
            }

            LabeledContent("Post confidence") {
                Text(post.postConfidence.title)
            }
            LabeledContent("Placement confidence") {
                Text(post.placementConfidence.title)
            }

            CatalogReasonList(reasons: post.postReasons + post.matchReasons)
            CatalogProvenanceList(
                provenance: post.provenance + post.matchedCircleProvenance
            )
        }
        .padding(.vertical, 4)
    }
}

private struct CatalogAttendanceDecisionSourceRow: View {
    let claim: CatalogAttendanceClaim

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if let policyID = claim.matchingPolicyID {
                LabeledContent("Matching policy", value: policyID)
            }
            if let policyID = claim.policyID {
                LabeledContent("Attendance policy", value: policyID)
            }

            LabeledContent("Attendance confidence") {
                Text(claim.confidence.title)
            }

            CatalogReasonList(reasons: claim.reasons + claim.matchReasons)
            CatalogProvenanceList(
                provenance: claim.provenance + claim.matchedCircleProvenance
            )
        }
        .padding(.vertical, 4)
    }

    private var title: LocalizedStringResource {
        claim.status == .withdrawn ? "Withdrawal match" : "Attendance match"
    }
}

private struct CatalogReasonList: View {
    let reasons: [String]

    var body: some View {
        if !uniqueReasons.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Match reasons")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(uniqueReasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var uniqueReasons: [String] {
        var seen: Set<String> = []
        return reasons.filter { seen.insert($0).inserted }
    }
}

private struct CatalogProvenanceList: View {
    let provenance: [CatalogRecordProvenance]

    var body: some View {
        if !uniqueProvenance.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source records")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(uniqueProvenance) { record in
                    CatalogProvenanceRecordRow(record: record)
                }
            }
        }
    }

    private var uniqueProvenance: [CatalogRecordProvenance] {
        var seen: Set<CatalogRecordProvenance> = []
        return provenance.filter { seen.insert($0).inserted }
    }
}

private struct CatalogProvenanceRecordRow: View {
    let record: CatalogRecordProvenance

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let url = record.url {
                Link(destination: url) {
                    LucideLabel(verbatim: sourceName, icon: "arrow.up.right")
                        .font(.subheadline)
                }
            } else {
                Text(sourceName)
                    .font(.subheadline)
            }

            if let recordID = record.recordID {
                Text(recordID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let retrievedAt = record.retrievedAt {
                Text("Retrieved: \(retrievedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceName: String {
        record.sourceID ?? record.sourceKind ?? String(localized: "Source record")
    }
}

private struct CatalogTagSourceRow: View {
    let tag: CatalogEnrichmentTag

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tag.canonicalLabel)
                .font(.headline)

            if let evidenceLine = tag.evidenceLine {
                LabeledContent("OCR evidence", value: evidenceLine)
            }

            if tag.provenance.isEmpty {
                Text("Detected from shinagaki text or OCR by the collector's tag matcher.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(uniqueProvenance, id: \.id) { provenance in
                    if let url = provenance.url {
                        Link(destination: url) {
                            LucideLabel(verbatim: provenance.title, icon: "arrow.up.right")
                        }
                    } else {
                        Text(provenance.title)
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var uniqueProvenance: [CatalogTagSource] {
        var seen: Set<CatalogTagSource> = []
        return tag.provenance.compactMap(CatalogTagSource.init).filter {
            seen.insert($0).inserted
        }
    }
}

private struct CatalogTagSource: Identifiable, Hashable {
    let sourceID: String?
    let recordID: String?
    let url: URL?

    init?(_ provenance: CatalogTagProvenance) {
        sourceID = provenance.sourceID.nonBlank
        recordID = provenance.recordID.nonBlank
        if let rawURL = provenance.url.nonBlank,
           let candidate = URL(string: rawURL),
           ["http", "https"].contains(candidate.scheme?.lowercased()) {
            url = candidate
        } else {
            url = nil
        }

        guard sourceID != nil || recordID != nil || url != nil else { return nil }
    }

    var id: String {
        [sourceID ?? "", recordID ?? "", url?.absoluteString ?? ""]
            .joined(separator: "\u{1f}")
    }

    var title: String {
        let value = [sourceID, recordID].compactMap { $0 }.joined(separator: " · ")
        return value.isEmpty ? String(localized: "Tag source") : value
    }
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(post.authorName.nonBlank ?? "@\(post.authorHandle)")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)

                if post.authorName.nonBlank != nil {
                    Text("@\(post.authorHandle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                ShinagakiConfidenceBadge(post: post)
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

private struct ShinagakiConfidenceBadge: View {
    let post: CatalogShinagakiPost

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(post.isHighConfidence ? Color.green : Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (post.isHighConfidence ? Color.green : Color.orange).opacity(0.12),
                in: .capsule
            )
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var title: LocalizedStringResource {
        post.isHighConfidence ? "High confidence" : "Possible match"
    }

    private var accessibilityLabel: LocalizedStringResource {
        post.isHighConfidence
            ? "High-confidence post and placement match"
            : "Possible automated placement match"
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
                        Color(uiColor: .secondarySystemFill)

                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                .aspectRatio(
                    ShinagakiArtworkLayout.a4PortraitAspectRatio,
                    contentMode: .fit
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
