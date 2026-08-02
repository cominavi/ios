import SwiftUI
import UIKit

struct CircleDetailView: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource

    @State private var details: CatalogCircleDetails?
    @State private var hasEnrichmentArchive = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                CircleDetailHeader(
                    circle: circle,
                    dataSource: dataSource,
                    spaceLabel: spaceLabel
                )

                if !shinagakiPosts.isEmpty {
                    CircleDetailShinagakiSection(posts: shinagakiPosts)
                } else if hasEnrichmentArchive, details != nil {
                    CircleDetailSection("Shinagaki") {
                        ContentUnavailableView(
                            "No matched shinagaki",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("No crawl post could be matched confidently to this circle.")
                        )
                        .frame(maxWidth: .infinity)
                    }
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
                        contentInsets: EdgeInsets(
                            top: 0,
                            leading: 16,
                            bottom: 0,
                            trailing: 16
                        )
                    ) {
                        VStack(spacing: 0) {
                            ForEach(externalLinks) { item in
                                Link(destination: item.url) {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.systemImage)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 24)
                                            .accessibilityHidden(true)

                                        Text(item.title)
                                            .foregroundStyle(.primary)

                                        Spacer(minLength: 12)

                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.tertiary)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(minHeight: 50)
                                    .contentShape(.rect)
                                }
                                .accessibilityHint("Opens in your browser")
                                .accessibilityIdentifier(item.accessibilityIdentifier)

                                if item.id != externalLinks.last?.id {
                                    Divider()
                                        .padding(.leading, 36)
                                }
                            }
                        }
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
                subtitle: spaceLabel
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .task(id: circle.id) {
            async let loadedDetails = dataSource.getCircleDetails(circleID: circle.id)
            async let statistics = dataSource.enrichmentStatistics()
            details = await loadedDetails
            hasEnrichmentArchive = await statistics != nil
        }
        .accessibilityIdentifier("circle-detail-screen")
    }

    private var hasAboutInformation: Bool {
        circle.bookName.nonBlank != nil
            || circle.description.nonBlank != nil
            || circle.memo.nonBlank != nil
    }

    private var shinagakiPosts: [CatalogShinagakiPost] {
        details?.enrichment?.posts ?? []
    }

    private var spaceLabel: String? {
        guard let blockID = circle.blockId,
              let block = dataSource.comiket.blocks.first(where: {
                  $0.externalBlockId == blockID
              }),
              let spaceNumber = circle.spaceNo
        else { return nil }

        let side = circle.spaceNoSub == 1 ? "b" : "a"
        return "\(block.name)\(String(format: "%02d", spaceNumber))\(side)"
    }

    private var externalLinks: [CircleExternalLink] {
        var links: [CircleExternalLink] = []
        var seen: Set<String> = []

        func append(
            _ title: LocalizedStringResource,
            systemImage: String,
            rawURL: String?,
            accessibilityIdentifier: String
        ) {
            guard let url = normalizedWebURL(rawURL),
                  seen.insert(url.absoluteString).inserted
            else { return }
            links.append(
                CircleExternalLink(
                    title: String(localized: title),
                    systemImage: systemImage,
                    url: url,
                    accessibilityIdentifier: accessibilityIdentifier
                )
            )
        }

        append(
            "Website",
            systemImage: "globe",
            rawURL: circle.url,
            accessibilityIdentifier: "circle-link-website"
        )
        append(
            "Circle.ms",
            systemImage: "person.2.crop.square.stack",
            rawURL: circle.circlems,
            accessibilityIdentifier: "circle-link-circlems"
        )
        append(
            "Circle.ms portal",
            systemImage: "person.2.crop.square.stack",
            rawURL: details?.extensionRecord?.CirclemsPortalURL,
            accessibilityIdentifier: "circle-link-circlems-portal"
        )
        append(
            "X profile",
            systemImage: "at",
            rawURL: details?.extensionRecord?.twitterURL.nonBlank
                ?? details?.enrichment?.primaryPost?.authorProfileURL?.absoluteString,
            accessibilityIdentifier: "circle-link-x"
        )
        append(
            "Pixiv",
            systemImage: "paintbrush.pointed",
            rawURL: details?.extensionRecord?.pixivURL,
            accessibilityIdentifier: "circle-link-pixiv"
        )
        return links
    }

    private func normalizedWebURL(_ rawValue: String?) -> URL? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }

        if let url = URL(string: value),
           ["http", "https"].contains(url.scheme?.lowercased())
        {
            return url
        }
        return URL(string: "https://\(value)")
    }
}

private struct CircleDetailHeader: View {
    let circle: CirclemsDataSchema.ComiketCircleWC
    let dataSource: CirclemsDataSource
    let spaceLabel: String?

    @State private var image: Image?
    @ScaledMetric(relativeTo: .title) private var artworkWidth = 154.0

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemFill))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .aspectRatio(180 / 256, contentMode: .fit)
            .frame(width: artworkWidth)
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 0.5)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(circle.circleName.nonBlank ?? String(localized: "Unnamed circle"))
                    .font(.title2.weight(.bold))
                    .textSelection(.enabled)

                if let penName = circle.penName.nonBlank {
                    Text(penName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let spaceLabel {
                    Label(spaceLabel, systemImage: "mappin.and.ellipse")
                        .font(.headline.monospaced())
                        .foregroundStyle(Color.accentColor)
                }

                if let day = circle.day {
                    Label("Day \(day)", systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: circle.id) {
            let data = await dataSource.getCircleImage(circleId: circle.id)
            image = await Image.asyncInit(data: data)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("circle-detail-header")
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
            Image(systemName: "exclamationmark.triangle.fill")
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
                    Label("Open shinagaki on X", systemImage: "arrow.up.right")
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

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
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
                ContentUnavailableView(
                    "Image unavailable",
                    systemImage: "photo.badge.exclamationmark"
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
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(media, id: \.self) { item in
                        ShinagakiRemoteImage(
                            media: item,
                            accessibilityLabel: accessibilityLabel
                        )
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        }
        .aspectRatio(
            ShinagakiArtworkLayout.a4PortraitAspectRatio,
            contentMode: .fit
        )
        .frame(maxWidth: .infinity)
    }
}

private struct CircleExternalLink: Identifiable {
    let title: String
    let systemImage: String
    let url: URL
    let accessibilityIdentifier: String

    var id: String { url.absoluteString }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
