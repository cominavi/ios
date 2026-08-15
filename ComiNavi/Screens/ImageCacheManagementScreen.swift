import Observation
import SwiftUI

@MainActor
@Observable
final class ImageCacheCategoryState: Identifiable {
    let category: RemoteImageCacheCategory
    nonisolated let id: RemoteImageCacheCategory
    var diskBytes: UInt = 0
    var limit: RemoteImageCacheLimit
    var isClearing = false
    var isApplyingLimit = false

    var isBusy: Bool {
        isClearing || isApplyingLimit
    }

    init(
        category: RemoteImageCacheCategory,
        defaults: UserDefaults = .standard
    ) {
        self.category = category
        id = category
        limit = RemoteImagePipeline.configuredLimit(
            for: category,
            defaults: defaults
        )
    }
}

@MainActor
@Observable
final class ImageCacheManagementModel {
    let categories: [ImageCacheCategoryState]
    private(set) var isRefreshing = false
    private(set) var isClearingAll = false
    private(set) var issueMessage: String?

    @ObservationIgnored private let defaults: UserDefaults

    var totalDiskBytes: UInt {
        categories.reduce(0) { $0 + $1.diskBytes }
    }

    var totalLimitBytes: UInt {
        categories.reduce(0) { $0 + $1.limit.bytes }
    }

    private var isMutating: Bool {
        isClearingAll || categories.contains(where: \.isBusy)
    }

    var isBusy: Bool {
        isRefreshing || isMutating
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        categories = RemoteImageCacheCategory.allCases.map {
            ImageCacheCategoryState(category: $0, defaults: defaults)
        }
    }

    func refresh() async {
        guard !isRefreshing, !isMutating else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let statistics = try await RemoteImagePipeline.allStatistics()
            let byCategory = Dictionary(
                uniqueKeysWithValues: statistics.map { ($0.category, $0) }
            )
            for state in categories {
                guard let value = byCategory[state.category] else { continue }
                state.diskBytes = value.diskBytes
            }
            issueMessage = nil
        } catch {
            issueMessage = String(
                localized: "Cache statistics are unavailable.",
                table: "ImageCache"
            )
        }
    }

    func applySelectedLimit(to state: ImageCacheCategoryState) async {
        guard !state.isApplyingLimit else { return }
        state.isApplyingLimit = true
        while true {
            let appliedLimit = state.limit
            await RemoteImagePipeline.setLimit(
                appliedLimit,
                for: state.category,
                defaults: defaults
            )
            guard state.limit != appliedLimit else { break }
        }
        state.isApplyingLimit = false
        await refresh()
    }

    func clear(_ state: ImageCacheCategoryState) async {
        guard !state.isClearing else { return }
        state.isClearing = true
        await RemoteImagePipeline.clear(state.category)
        state.diskBytes = 0
        state.isClearing = false
        issueMessage = nil
    }

    func clearAll() async {
        guard !isClearingAll else { return }
        isClearingAll = true
        categories.forEach { $0.isClearing = true }
        await RemoteImagePipeline.clearAll()
        for category in categories {
            category.diskBytes = 0
            category.isClearing = false
        }
        isClearingAll = false
        issueMessage = nil
    }
}

struct ImageCacheManagementScreen: View {
    @State private var model = ImageCacheManagementModel()
    @State private var isShowingClearAllConfirmation = false

    var body: some View {
        Form {
            ImageCacheSummarySection(
                usedBytes: model.totalDiskBytes,
                limitBytes: model.totalLimitBytes,
                isRefreshing: model.isRefreshing,
                isClearingAll: model.isClearingAll,
                isBusy: model.isBusy,
                onClearAll: { isShowingClearAllConfirmation = true }
            )

            ForEach(model.categories) { state in
                ImageCacheCategorySection(state: state, model: model)
            }

            if let issueMessage = model.issueMessage {
                Section {
                    Text(issueMessage)
                        .foregroundStyle(.orange)

                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Text("Try Again", tableName: "ImageCache")
                    }
                }
            }
        }
        .navigationTitle(Text("Image Cache", tableName: "ImageCache"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .accessibilityLabel(
                    Text("Refresh Cache Statistics", tableName: "ImageCache")
                )
            }
        }
        .task {
            await model.refresh()
        }
        .refreshable {
            await model.refresh()
        }
        .confirmationDialog(
            String(
                localized: "Clear all image caches?",
                table: "ImageCache"
            ),
            isPresented: $isShowingClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.clearAll() }
            } label: {
                Text("Clear All", tableName: "ImageCache")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", tableName: "ImageCache")
            }
        } message: {
            Text(
                "Downloaded images will be removed and downloaded again when needed.",
                tableName: "ImageCache"
            )
        }
        .accessibilityIdentifier("image-cache-screen")
    }
}

private struct ImageCacheSummarySection: View {
    let usedBytes: UInt
    let limitBytes: UInt
    let isRefreshing: Bool
    let isClearingAll: Bool
    let isBusy: Bool
    let onClearAll: () -> Void

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    CacheByteCountText(bytes: usedBytes)
                }
            } label: {
                Text("Used", tableName: "ImageCache")
            }

            LabeledContent {
                Text(Int64(limitBytes), format: .byteCount(style: .memory))
                    .monospacedDigit()
            } label: {
                Text("Combined limit", tableName: "ImageCache")
            }

            Button(role: .destructive, action: onClearAll) {
                HStack(spacing: 8) {
                    if isClearingAll {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Clear All Image Caches", tableName: "ImageCache")
                }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("image-cache-clear-all")
        } header: {
            Text("Storage", tableName: "ImageCache")
        } footer: {
            Text(
                "Image caches keep downloaded images available without downloading them again.",
                tableName: "ImageCache"
            )
        }
    }
}

private struct ImageCacheCategorySection: View {
    @Bindable var state: ImageCacheCategoryState
    let model: ImageCacheManagementModel

    var body: some View {
        Section {
            LabeledContent {
                CacheByteCountText(bytes: state.diskBytes)
            } label: {
                Text("Used", tableName: "ImageCache")
            }

            CacheUsageBar(
                usedBytes: state.diskBytes,
                limitBytes: state.limit.bytes
            )

            Picker(selection: $state.limit) {
                ForEach(RemoteImageCacheLimit.allCases) { limit in
                    Text(Int64(limit.bytes), format: .byteCount(style: .memory))
                        .tag(limit)
                }
            } label: {
                Text("Disk limit", tableName: "ImageCache")
            }
            .disabled(model.isBusy)
            .onChange(of: state.limit) { oldLimit, newLimit in
                guard oldLimit != newLimit else { return }
                Task { await model.applySelectedLimit(to: state) }
            }
            .accessibilityIdentifier("image-cache-\(state.category.rawValue)-limit")

            Button(role: .destructive) {
                Task { await model.clear(state) }
            } label: {
                HStack(spacing: 8) {
                    if state.isClearing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Clear Cache", tableName: "ImageCache")
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("image-cache-\(state.category.rawValue)-clear")
        } header: {
            Label {
                Text(state.category.title)
            } icon: {
                Image(systemName: state.category.systemImage)
            }
        } footer: {
            Text(state.category.detail)
        }
    }
}

private struct CacheByteCountText: View {
    let bytes: UInt

    var body: some View {
        if bytes == 0 {
            Text(verbatim: "0 KB")
                .monospacedDigit()
        } else {
            Text(Int64(bytes), format: .byteCount(style: .file))
                .monospacedDigit()
        }
    }
}

private struct CacheUsageBar: View {
    let usedBytes: UInt
    let limitBytes: UInt

    private var fraction: CGFloat {
        guard limitBytes > 0 else { return 0 }
        return min(CGFloat(usedBytes) / CGFloat(limitBytes), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))

                if fraction > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private extension RemoteImageCacheCategory {
    var title: LocalizedStringResource {
        switch self {
        case .shinagaki:
            LocalizedStringResource("Shinagaki images", table: "ImageCache")
        case .circleArtwork:
            LocalizedStringResource("Circle artwork", table: "ImageCache")
        case .profileImages:
            LocalizedStringResource("Profile images", table: "ImageCache")
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .shinagaki:
            LocalizedStringResource(
                "Product previews and Shinagaki images shown in Explore and circle details.",
                table: "ImageCache"
            )
        case .circleArtwork:
            LocalizedStringResource(
                "Higher-resolution Circle.ms circle cuts.",
                table: "ImageCache"
            )
        case .profileImages:
            LocalizedStringResource(
                "ComiNavi, X, and followed-account profile images.",
                table: "ImageCache"
            )
        }
    }

    var systemImage: String {
        switch self {
        case .shinagaki: "photo.on.rectangle.angled"
        case .circleArtwork: "person.crop.square"
        case .profileImages: "person.crop.circle"
        }
    }
}
