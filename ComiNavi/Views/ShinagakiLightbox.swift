import SwiftUI
import UIKit

enum ShinagakiArtworkLayout {
    static let a4PortraitAspectRatio = CGFloat(210) / CGFloat(297)
    static let maximumZoomMultiplier = CGFloat(6)
    static let doubleTapZoomMultiplier = CGFloat(2.5)

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

struct ShinagakiLightbox: View {
    let image: UIImage
    let accessibilityLabel: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                ZoomableShinagakiImage(
                    image: image,
                    accessibilityLabel: accessibilityLabel
                )
                .ignoresSafeArea()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
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
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) {
            dismiss()
        }
        .accessibilityIdentifier("shinagaki-lightbox")
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

    private static func displaySize(for image: UIImage) -> CGSize {
        // UIImage.size is already the logical, orientation-aware display size.
        image.size
    }
}
