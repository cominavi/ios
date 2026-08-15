import SwiftUI
import UIKit

enum ShinagakiArtworkLayout {
    static let a4PortraitAspectRatio = CGFloat(210) / CGFloat(297)
    static let maximumZoomMultiplier = CGFloat(6)
    static let doubleTapZoomMultiplier = CGFloat(2.5)

    static func previewAspectRatio(for imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return a4PortraitAspectRatio
        }
        return imageSize.width / imageSize.height
    }

    static func minimumZoomScale(
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> CGFloat {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return 1 }

        return min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
    }

    static func doubleTapTargetScale(
        currentScale: CGFloat,
        minimumScale: CGFloat,
        maximumScale: CGFloat
    ) -> CGFloat {
        guard minimumScale > 0, maximumScale >= minimumScale else {
            return currentScale
        }
        if currentScale > minimumScale + 0.01 {
            return minimumScale
        }
        return min(
            minimumScale * doubleTapZoomMultiplier,
            maximumScale
        )
    }

}

struct ShinagakiLightboxPage: Identifiable {
    let id: String
    let accessibilityLabel: String
    let image: UIImage?
    let originalURL: URL?
    let previewURL: URL?

    var displayURL: URL? {
        previewURL ?? originalURL
    }

    init(
        id: String,
        image: UIImage,
        accessibilityLabel: String
    ) {
        self.init(
            id: id,
            accessibilityLabel: accessibilityLabel,
            image: image,
            originalURL: nil,
            previewURL: nil
        )
    }

    init(
        id: String,
        media: CatalogShinagakiMedia,
        accessibilityLabel: String,
        image: UIImage? = nil
    ) {
        self.init(
            id: id,
            accessibilityLabel: accessibilityLabel,
            image: image,
            originalURL: media.url,
            previewURL: media.previewURL
        )
    }

    private init(
        id: String,
        accessibilityLabel: String,
        image: UIImage?,
        originalURL: URL?,
        previewURL: URL?
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.image = image
        self.originalURL = originalURL
        self.previewURL = previewURL
    }

    func withInitialImage(_ image: UIImage) -> Self {
        return Self(
            id: id,
            accessibilityLabel: accessibilityLabel,
            image: image,
            originalURL: originalURL,
            previewURL: previewURL
        )
    }

    static func pages(
        postID: String,
        media: [CatalogShinagakiMedia],
        accessibilityLabel: String
    ) -> [Self] {
        media.enumerated().map { index, item in
            let pageAccessibilityLabel = String(
                localized: "Image \(index + 1) of \(media.count): \(accessibilityLabel)",
                comment: "Accessibility label for one image in a multi-image Shinagaki post."
            )
            return Self(
                id: "\(postID)-media-\(index)",
                media: item,
                accessibilityLabel: pageAccessibilityLabel
            )
        }
    }
}

struct ShinagakiLightboxPresentation: Identifiable {
    let id = UUID()
    let pages: [ShinagakiLightboxPage]
    let selectedPageID: ShinagakiLightboxPage.ID

    init?(
        pages: [ShinagakiLightboxPage],
        selectedPageID: ShinagakiLightboxPage.ID
    ) {
        guard !pages.isEmpty,
              pages.contains(where: { $0.id == selectedPageID })
        else { return nil }
        self.pages = pages
        self.selectedPageID = selectedPageID
    }
}

struct ShinagakiLightbox: View {
    let pages: [ShinagakiLightboxPage]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPageID: ShinagakiLightboxPage.ID

    init(
        image: UIImage,
        accessibilityLabel: String
    ) {
        let page = ShinagakiLightboxPage(
            id: "single-image",
            image: image,
            accessibilityLabel: accessibilityLabel
        )
        pages = [page]
        _selectedPageID = State(initialValue: page.id)
    }

    init(presentation: ShinagakiLightboxPresentation) {
        pages = presentation.pages
        _selectedPageID = State(initialValue: presentation.selectedPageID)
    }

    init(
        pages: [ShinagakiLightboxPage],
        selectedPageID: ShinagakiLightboxPage.ID
    ) {
        precondition(!pages.isEmpty)
        self.pages = pages
        _selectedPageID = State(
            initialValue: pages.contains(where: { $0.id == selectedPageID })
                ? selectedPageID
                : pages[0].id
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                TabView(selection: $selectedPageID) {
                    ForEach(pages) { page in
                        ShinagakiLightboxPageView(page: page)
                            .tag(page.id)
                            .accessibilityIdentifier(
                                "shinagaki-lightbox-page-\(page.id)"
                            )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("shinagaki-lightbox")
                .ignoresSafeArea()

                Button {
                    dismiss()
                } label: {
                    LucideIcon("xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("shinagaki-lightbox-close")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, proxy.safeAreaInsets.top + 8)
                .padding(.trailing, 16)

                if pages.count > 1 {
                    Text("Page \(selectedPageIndex + 1) of \(pages.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: .capsule)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Page \(selectedPageIndex + 1) of \(pages.count)"
                        )
                        .accessibilityValue(
                            "\(selectedPageIndex + 1)/\(pages.count)"
                        )
                        .accessibilityAdjustableAction { direction in
                            movePage(direction)
                        }
                        .accessibilityIdentifier(
                            "shinagaki-lightbox-page-indicator"
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottom
                        )
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 16)
                }
            }
        }
        .background(Color.black)
        // Keep the dark controls local to the lightbox. `preferredColorScheme`
        // is a presentation-level preference and can change the presenting
        // app's appearance while this sheet is shown.
        .environment(\.colorScheme, .dark)
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var selectedPageIndex: Int {
        pages.firstIndex(where: { $0.id == selectedPageID }) ?? 0
    }

    private func movePage(_ direction: AccessibilityAdjustmentDirection) {
        let targetIndex: Int
        switch direction {
        case .increment:
            targetIndex = min(selectedPageIndex + 1, pages.count - 1)
        case .decrement:
            targetIndex = max(selectedPageIndex - 1, 0)
        @unknown default:
            return
        }
        selectedPageID = pages[targetIndex].id
    }
}

private struct ShinagakiLightboxPageView: View {
    let page: ShinagakiLightboxPage

    @State private var image: UIImage?
    @State private var didFail = false

    init(page: ShinagakiLightboxPage) {
        self.page = page
        _image = State(initialValue: page.image)
    }

    var body: some View {
        Group {
            if let image {
                ZoomableShinagakiImage(
                    image: image,
                    accessibilityLabel: page.accessibilityLabel
                )
            } else if didFail {
                LucideContentUnavailableView(
                    "Image unavailable",
                    icon: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: page.displayURL) {
            await loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() async {
        guard image == nil, let displayURL = page.displayURL else { return }
        didFail = false
        guard let decodedImage = await RemoteImagePipeline.image(
            for: displayURL,
            category: .shinagaki
        ),
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

private struct ZoomableShinagakiImage: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String

    func makeUIView(context: Context) -> ShinagakiZoomScrollView {
        let scrollView = ShinagakiZoomScrollView()
        scrollView.configure(
            image: image,
            accessibilityLabel: accessibilityLabel
        )
        return scrollView
    }

    func updateUIView(
        _ scrollView: ShinagakiZoomScrollView,
        context: Context
    ) {
        scrollView.configure(
            image: image,
            accessibilityLabel: accessibilityLabel
        )
    }
}

@MainActor
final class ShinagakiZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private struct ProgrammaticZoom {
        let imagePoint: CGPoint
        let targetScale: CGFloat
    }

    private let zoomImageView = UIImageView()
    private var displayedImage: UIImage?
    private var imageDisplaySize = CGSize.zero
    private var lastViewportSize = CGSize.zero
    private var hasAppliedInitialScale = false
    private var programmaticZoom: ProgrammaticZoom?
    private let zoomPercentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        bouncesZoom = true
        delaysContentTouches = false

        zoomImageView.backgroundColor = .black
        zoomImageView.contentMode = .scaleAspectFit
        zoomImageView.isAccessibilityElement = true
        zoomImageView.accessibilityIdentifier = "shinagaki-zoom-image"
        addSubview(zoomImageView)

        let doubleTapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTapRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapRecognizer)

        zoomImageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "Zoom in"),
                actionHandler: { [weak self] _ in
                    self?.zoomInForAccessibility() ?? false
                }
            ),
            UIAccessibilityCustomAction(
                name: String(localized: "Zoom out"),
                actionHandler: { [weak self] _ in
                    self?.zoomOutForAccessibility() ?? false
                }
            ),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        image: UIImage,
        accessibilityLabel: String
    ) {
        zoomImageView.accessibilityLabel = accessibilityLabel
        guard displayedImage !== image else { return }

        displayedImage = image
        zoomImageView.image = image
        imageDisplaySize = Self.displaySize(for: image)
        zoomImageView.frame = CGRect(origin: .zero, size: imageDisplaySize)
        contentSize = imageDisplaySize
        lastViewportSize = .zero
        hasAppliedInitialScale = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let viewportSize = bounds.size
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              imageDisplaySize.width > 0,
              imageDisplaySize.height > 0
        else { return }

        if viewportSize != lastViewportSize {
            let previousMinimum = minimumZoomScale
            let wasAtMinimum = !hasAppliedInitialScale
                || abs(zoomScale - previousMinimum) < 0.01
            let fittedScale = ShinagakiArtworkLayout.minimumZoomScale(
                imageSize: imageDisplaySize,
                viewportSize: viewportSize
            )

            minimumZoomScale = fittedScale
            maximumZoomScale = fittedScale
                * ShinagakiArtworkLayout.maximumZoomMultiplier
            lastViewportSize = viewportSize
            hasAppliedInitialScale = true

            if wasAtMinimum {
                setZoomScale(fittedScale, animated: false)
            } else {
                zoomScale = min(max(zoomScale, fittedScale), maximumZoomScale)
            }
        }

        centerImageIfNeeded()
        updateAccessibilityZoomValue()
        updatePanGestureAvailability()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomImageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
        if let programmaticZoom {
            centerImagePointInViewport(programmaticZoom.imagePoint)
            if abs(zoomScale - programmaticZoom.targetScale) < 0.001 {
                self.programmaticZoom = nil
            }
        }
        updateAccessibilityZoomValue()
        updatePanGestureAvailability()
    }

    func scrollViewWillBeginZooming(
        _ scrollView: UIScrollView,
        with view: UIView?
    ) {
        // This delegate callback also fires for animated setZoomScale calls.
        // Only a real pinch should take ownership from a double-tap animation.
        if pinchGestureRecognizer?.state == .began {
            programmaticZoom = nil
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Do not keep pulling toward an old double-tap anchor once the user drags.
        programmaticZoom = nil
    }

    func toggleZoom(
        at imagePoint: CGPoint,
        animated: Bool
    ) {
        layoutIfNeeded()
        let targetScale = ShinagakiArtworkLayout.doubleTapTargetScale(
            currentScale: zoomScale,
            minimumScale: minimumZoomScale,
            maximumScale: maximumZoomScale
        )

        if targetScale <= minimumZoomScale + 0.01 {
            zoom(
                toScale: minimumZoomScale,
                centeredAt: CGPoint(
                    x: zoomImageView.bounds.midX,
                    y: zoomImageView.bounds.midY
                ),
                animated: animated
            )
            return
        }

        let clampedPoint = CGPoint(
            x: min(max(imagePoint.x, zoomImageView.bounds.minX), zoomImageView.bounds.maxX),
            y: min(max(imagePoint.y, zoomImageView.bounds.minY), zoomImageView.bounds.maxY)
        )
        zoom(
            toScale: targetScale,
            centeredAt: clampedPoint,
            animated: animated
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        toggleZoom(
            at: recognizer.location(in: zoomImageView),
            animated: true
        )
    }

    private func zoomInForAccessibility() -> Bool {
        layoutIfNeeded()
        guard maximumZoomScale > minimumZoomScale + 0.01 else { return false }
        let targetScale = min(
            max(
                zoomScale * 2,
                minimumZoomScale * ShinagakiArtworkLayout.doubleTapZoomMultiplier
            ),
            maximumZoomScale
        )
        guard targetScale > zoomScale + 0.01 else { return false }
        zoom(
            toScale: targetScale,
            centeredAt: imagePointAtViewportCenter(),
            animated: true
        )
        return true
    }

    private func zoomOutForAccessibility() -> Bool {
        layoutIfNeeded()
        guard zoomScale > minimumZoomScale + 0.01 else { return false }
        zoom(
            toScale: minimumZoomScale,
            centeredAt: CGPoint(
                x: zoomImageView.bounds.midX,
                y: zoomImageView.bounds.midY
            ),
            animated: true
        )
        return true
    }

    private func zoom(
        toScale targetScale: CGFloat,
        centeredAt imagePoint: CGPoint,
        animated: Bool
    ) {
        programmaticZoom = ProgrammaticZoom(
            imagePoint: imagePoint,
            targetScale: targetScale
        )
        setZoomScale(targetScale, animated: animated)
        if !animated {
            centerImageIfNeeded()
            centerImagePointInViewport(imagePoint)
            programmaticZoom = nil
            updateAccessibilityZoomValue()
        }
    }

    private func centerImagePointInViewport(_ imagePoint: CGPoint) {
        let imageBounds = zoomImageView.bounds
        let imageFrame = zoomImageView.frame
        guard imageBounds.width > 0,
              imageBounds.height > 0,
              imageFrame.width > 0,
              imageFrame.height > 0
        else { return }

        let contentPoint = CGPoint(
            x: imageFrame.minX
                + (imagePoint.x - imageBounds.minX)
                    / imageBounds.width * imageFrame.width,
            y: imageFrame.minY
                + (imagePoint.y - imageBounds.minY)
                    / imageBounds.height * imageFrame.height
        )
        let minimumOffset = CGPoint(
            x: -adjustedContentInset.left,
            y: -adjustedContentInset.top
        )
        let maximumOffset = CGPoint(
            x: max(
                minimumOffset.x,
                contentSize.width - bounds.width + adjustedContentInset.right
            ),
            y: max(
                minimumOffset.y,
                contentSize.height - bounds.height + adjustedContentInset.bottom
            )
        )
        contentOffset = CGPoint(
            x: min(
                max(contentPoint.x - bounds.width / 2, minimumOffset.x),
                maximumOffset.x
            ),
            y: min(
                max(contentPoint.y - bounds.height / 2, minimumOffset.y),
                maximumOffset.y
            )
        )
    }

    private func imagePointAtViewportCenter() -> CGPoint {
        let imageBounds = zoomImageView.bounds
        let imageFrame = zoomImageView.frame
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            return CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        }
        return CGPoint(
            x: imageBounds.minX
                + (bounds.midX - imageFrame.minX)
                    / imageFrame.width * imageBounds.width,
            y: imageBounds.minY
                + (bounds.midY - imageFrame.minY)
                    / imageFrame.height * imageBounds.height
        )
    }

    private func centerImageIfNeeded() {
        var frame = zoomImageView.frame
        frame.origin.x = frame.width < bounds.width
            ? (bounds.width - frame.width) / 2
            : 0
        frame.origin.y = frame.height < bounds.height
            ? (bounds.height - frame.height) / 2
            : 0
        zoomImageView.frame = frame
    }

    private func updateAccessibilityZoomValue() {
        guard minimumZoomScale > 0 else { return }
        zoomImageView.accessibilityValue = zoomPercentFormatter.string(
            from: NSNumber(value: zoomScale / minimumZoomScale)
        )
    }

    private func updatePanGestureAvailability() {
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale + 0.01
    }

    private static func displaySize(for image: UIImage) -> CGSize {
        // UIImage.size is already the logical, orientation-aware display size.
        image.size
    }
}
