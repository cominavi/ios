import SwiftUI
import UIKit

struct ExploreGalleryCollection<Header: View>: UIViewRepresentable {
    let circles: [ExploreCircle]
    let model: ExploreModel
    let onSelect: (Int) -> Void
    let headerLayoutVersion: Int
    let header: Header

    init(
        circles: [ExploreCircle],
        model: ExploreModel,
        onSelect: @escaping (Int) -> Void,
        headerLayoutVersion: Int,
        @ViewBuilder header: () -> Header
    ) {
        self.circles = circles
        self.model = model
        self.onSelect = onSelect
        self.headerLayoutVersion = headerLayoutVersion
        self.header = header()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 18
        layout.sectionInset = UIEdgeInsets(
            top: 0,
            left: ExploreLayoutMetrics.horizontalContentInset,
            bottom: 0,
            right: ExploreLayoutMetrics.horizontalContentInset
        )

        let collectionView = ExploreTouchCancellingCollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 2)
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.cellIdentifier)
        collectionView.register(
            ExploreGalleryHeaderReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: Coordinator.headerIdentifier
        )
        collectionView.accessibilityIdentifier = "explore-gallery"
        collectionView.accessibilityLabel = String(localized: "Circle gallery")

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(pinch)

        context.coordinator.install(on: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject,
        UICollectionViewDataSource,
        UICollectionViewDelegateFlowLayout,
        UIGestureRecognizerDelegate
    {
        static var cellIdentifier: String { "ExploreGalleryCircle" }
        static var headerIdentifier: String { "ExploreGalleryHeader" }

        private struct PinchAnchor {
            let circleIndex: Int
            let indexPath: IndexPath
            let itemUnitPoint: CGPoint
            var viewportPoint: CGPoint
            let initialColumns: CGFloat
        }

        private var parent: ExploreGalleryCollection
        private weak var collectionView: UICollectionView?
        private var circleIDs: [Int]
        private var columnCount: CGFloat = 2
        private var renderedCardDetail: ExploreGalleryCardDetail = .full
        private var leadingPlaceholderCount = 0
        private var pinchAnchor: PinchAnchor?
        private var measuredHeaderSize: CGSize?
        private var visibleArtworkPixelSize: ExploreArtworkPixelSize?

        init(parent: ExploreGalleryCollection) {
            self.parent = parent
            circleIDs = parent.circles.map(\.id)
        }

        func install(on collectionView: UICollectionView) {
            self.collectionView = collectionView
            if let collectionView = collectionView as? ExploreTouchCancellingCollectionView {
                collectionView.onBoundsSizeChange = { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.refreshVisibleArtworkIfNeeded(in: collectionView)
                }
            }
            updateAccessibility()
            collectionView.accessibilityCustomActions = [
                UIAccessibilityCustomAction(
                    name: String(localized: "Zoom in"),
                    actionHandler: { [weak self] _ in
                        self?.stepZoom(towardFewerColumns: true) ?? false
                    }
                ),
                UIAccessibilityCustomAction(
                    name: String(localized: "Zoom out"),
                    actionHandler: { [weak self] _ in
                        self?.stepZoom(towardFewerColumns: false) ?? false
                    }
                ),
            ]
        }

        func update(parent: ExploreGalleryCollection) {
            let headerLayoutChanged = parent.headerLayoutVersion != self.parent.headerLayoutVersion
            self.parent = parent
            if let collectionView {
                for header in collectionView.visibleSupplementaryViews(
                    ofKind: UICollectionView.elementKindSectionHeader
                ) {
                    (header as? ExploreGalleryHeaderReusableView)?.configure(with: parent.header)
                }
                if headerLayoutChanged {
                    measuredHeaderSize = nil
                    collectionView.collectionViewLayout.invalidateLayout()
                }
                refreshVisibleArtworkIfNeeded(in: collectionView)
            }
            let updatedIDs = parent.circles.map(\.id)
            guard updatedIDs != circleIDs else { return }
            circleIDs = updatedIDs
            leadingPlaceholderCount = 0
            pinchAnchor = nil
            if let collectionView {
                visibleArtworkPixelSize = ExploreLayoutMetrics.artworkPixelSize(
                    width: itemWidth(in: collectionView),
                    displayScale: collectionView.traitCollection.displayScale
                )
            } else {
                visibleArtworkPixelSize = nil
            }
            collectionView?.reloadData()
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            parent.circles.count + leadingPlaceholderCount
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.cellIdentifier,
                for: indexPath
            )
            guard let circleIndex = circleIndex(for: indexPath) else {
                cell.contentConfiguration = nil
                cell.accessibilityIdentifier = ""
                cell.accessibilityElementsHidden = true
                cell.isUserInteractionEnabled = false
                return cell
            }
            let circle = parent.circles[circleIndex]
            let itemWidth = itemWidth(in: collectionView)
            let artworkPixelSize = ExploreLayoutMetrics.artworkPixelSize(
                width: itemWidth,
                displayScale: collectionView.traitCollection.displayScale
            )
            cell.contentConfiguration = UIHostingConfiguration {
                ExploreGalleryCard(
                    circle: circle,
                    model: parent.model,
                    artworkPixelSize: artworkPixelSize,
                    detail: renderedCardDetail
                )
            }
            .margins(.all, 0)
            cell.backgroundColor = .clear
            cell.accessibilityIdentifier = "explore-gallery-circle-\(circle.id)"
            cell.accessibilityElementsHidden = false
            cell.isUserInteractionEnabled = true
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard let circleIndex = circleIndex(for: indexPath) else { return }
            parent.onSelect(parent.circles[circleIndex].id)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            let width = itemWidth(in: collectionView)
            let artworkHeight = width * 300 / 211
            if renderedCardDetail == .artworkOnly {
                return CGSize(width: width, height: artworkHeight)
            }
            let headlineHeight = UIFont.preferredFont(forTextStyle: .headline).lineHeight * 2
            let hasGenre = renderedCardDetail == .full
                && circleIndex(for: indexPath).map { parent.circles[$0].genreName != nil } == true
            let genreHeight = hasGenre
                ? 8 + UIFont.preferredFont(forTextStyle: .caption1).lineHeight
                : 0
            return CGSize(
                width: width,
                height: artworkHeight + 8 + headlineHeight + genreHeight
            )
        }

        private func itemWidth(in collectionView: UICollectionView) -> CGFloat {
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            let spacing = flowLayout?.minimumInteritemSpacing ?? 12
            let sectionInset = flowLayout?.sectionInset ?? .zero
            let horizontalInsets = sectionInset.left + sectionInset.right
            let availableWidth = max(collectionView.bounds.width - horizontalInsets, 1)
            let totalSpacing = spacing * max(columnCount - 1, 0)
            return max(
                floor((availableWidth - totalSpacing) / columnCount * 100) / 100 - 0.01,
                1
            )
        }

        private func refreshVisibleArtworkIfNeeded(
            in collectionView: UICollectionView
        ) {
            let pixelSize = ExploreLayoutMetrics.artworkPixelSize(
                width: itemWidth(in: collectionView),
                displayScale: collectionView.traitCollection.displayScale
            )
            guard pixelSize != visibleArtworkPixelSize else { return }
            visibleArtworkPixelSize = pixelSize
            measuredHeaderSize = nil
            collectionView.collectionViewLayout.invalidateLayout()

            let visibleItems = collectionView.indexPathsForVisibleItems.filter {
                circleIndex(for: $0) != nil
            }
            if !visibleItems.isEmpty {
                collectionView.reconfigureItems(at: visibleItems)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: Self.headerIdentifier,
                for: indexPath
            ) as! ExploreGalleryHeaderReusableView
            header.configure(with: parent.header)
            return header
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> CGSize {
            let width = max(
                collectionView.bounds.width
                    - collectionView.adjustedContentInset.left
                    - collectionView.adjustedContentInset.right,
                1
            )
            return CGSize(width: width, height: measuredHeaderHeight(width: width))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer
                || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let collectionView else { return }
            switch gesture.state {
            case .began:
                collectionView.layer.removeAllAnimations()
                collectionView.setContentOffset(collectionView.contentOffset, animated: false)
                pinchAnchor = makeAnchor(
                    at: gesture.location(in: collectionView),
                    initialColumns: columnCount
                )

            case .changed:
                guard var anchor = pinchAnchor else { return }
                let contentPoint = gesture.location(in: collectionView)
                anchor.viewportPoint = viewportPoint(
                    for: contentPoint,
                    in: collectionView
                )
                pinchAnchor = anchor
                let columns = ExploreGalleryZoomGeometry.columns(
                    initialColumns: anchor.initialColumns,
                    magnification: gesture.scale
                )
                applyInteractive(columns: columns, preserving: anchor)

            case .ended, .cancelled, .failed:
                guard let anchor = pinchAnchor else { return }
                let snappedColumns = ExploreGalleryZoomGeometry.nearestColumnLevel(to: columnCount)
                pinchAnchor = nil
                finishZoom(columns: snappedColumns, preserving: anchor)

            default:
                break
            }
        }

        private func makeAnchor(
            at contentPoint: CGPoint,
            initialColumns: CGFloat
        ) -> PinchAnchor? {
            guard let collectionView,
                  let attributes = anchorAttributes(at: contentPoint, in: collectionView),
                  let circleIndex = circleIndex(for: attributes.indexPath)
            else {
                return nil
            }
            return PinchAnchor(
                circleIndex: circleIndex,
                indexPath: attributes.indexPath,
                itemUnitPoint: ExploreGalleryZoomGeometry.unitPoint(
                    in: attributes.frame,
                    at: contentPoint
                ),
                viewportPoint: viewportPoint(for: contentPoint, in: collectionView),
                initialColumns: initialColumns
            )
        }

        private func anchorAttributes(
            at contentPoint: CGPoint,
            in collectionView: UICollectionView
        ) -> UICollectionViewLayoutAttributes? {
            if let indexPath = collectionView.indexPathForItem(at: contentPoint),
               circleIndex(for: indexPath) != nil,
               let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            {
                return attributes
            }
            return collectionView.collectionViewLayout
                .layoutAttributesForElements(in: collectionView.bounds)?
                .filter {
                    $0.representedElementCategory == .cell
                        && circleIndex(for: $0.indexPath) != nil
                }
                .min { lhs, rhs in
                    lhs.center.distanceSquared(to: contentPoint)
                        < rhs.center.distanceSquared(to: contentPoint)
                }
        }

        private func viewportPoint(
            for contentPoint: CGPoint,
            in collectionView: UICollectionView
        ) -> CGPoint {
            CGPoint(
                x: contentPoint.x - collectionView.bounds.minX,
                y: contentPoint.y - collectionView.bounds.minY
            )
        }

        private func applyInteractive(
            columns: CGFloat,
            preserving anchor: PinchAnchor
        ) {
            guard let collectionView else { return }
            guard abs(columnCount - columns) > 0.000_1 else {
                collectionView.layoutIfNeeded()
                restore(anchor: anchor, in: collectionView)
                return
            }
            columnCount = columns
            collectionView.collectionViewLayout.invalidateLayout()
            UIView.performWithoutAnimation {
                collectionView.layoutIfNeeded()
                restore(anchor: anchor, in: collectionView)
            }
        }

        private func finishZoom(
            columns: CGFloat,
            preserving anchor: PinchAnchor
        ) {
            guard let collectionView else { return }
            let targetDetail = Self.cardDetail(for: columns)
            let detailChanged = renderedCardDetail != targetDetail
            let targetPlaceholderCount = placeholderCount(
                aligning: anchor.circleIndex,
                with: anchor.viewportPoint.x,
                columns: Int(columns)
            )
            let phaseChanged = leadingPlaceholderCount != targetPlaceholderCount
            columnCount = columns
            visibleArtworkPixelSize = ExploreLayoutMetrics.artworkPixelSize(
                width: itemWidth(in: collectionView),
                displayScale: collectionView.traitCollection.displayScale
            )
            renderedCardDetail = targetDetail
            leadingPlaceholderCount = targetPlaceholderCount
            let alignedAnchor = PinchAnchor(
                circleIndex: anchor.circleIndex,
                indexPath: IndexPath(
                    item: anchor.circleIndex + leadingPlaceholderCount,
                    section: 0
                ),
                itemUnitPoint: anchor.itemUnitPoint,
                viewportPoint: anchor.viewportPoint,
                initialColumns: anchor.initialColumns
            )
            collectionView.collectionViewLayout.invalidateLayout()
            let columnLevelChanged = abs(anchor.initialColumns - columns) > 0.01
            if phaseChanged {
                collectionView.reloadData()
            } else if detailChanged || columnLevelChanged {
                collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems)
            }

            let updates = { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                collectionView.layoutIfNeeded()
                self.restore(anchor: alignedAnchor, in: collectionView)
            }
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: updates,
                completion: { [weak self, weak collectionView] _ in
                    guard let self, let collectionView else { return }
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                    self.restore(anchor: alignedAnchor, in: collectionView)
                    self.updateAccessibility()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: String(localized: "\(Int(columns)) columns")
                    )
                }
            )
        }

        private func circleIndex(for indexPath: IndexPath) -> Int? {
            let circleIndex = indexPath.item - leadingPlaceholderCount
            guard parent.circles.indices.contains(circleIndex) else { return nil }
            return circleIndex
        }

        private func measuredHeaderHeight(width: CGFloat) -> CGFloat {
            if let measuredHeaderSize, abs(measuredHeaderSize.width - width) < 0.5 {
                return measuredHeaderSize.height
            }
            let contentView = UIHostingConfiguration {
                parent.header
            }
            .margins(.all, 0)
            .makeContentView()
            let fittingSize = contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            let measuredSize = CGSize(width: width, height: ceil(fittingSize.height))
            measuredHeaderSize = measuredSize
            return measuredSize.height
        }

        private func placeholderCount(
            aligning circleIndex: Int,
            with viewportX: CGFloat,
            columns: Int
        ) -> Int {
            guard let collectionView, columns > 0 else { return 0 }
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            let spacing = flowLayout?.minimumInteritemSpacing ?? 12
            let sectionInset = flowLayout?.sectionInset ?? .zero
            let horizontalInsets = sectionInset.left + sectionInset.right
            let availableWidth = max(collectionView.bounds.width - horizontalInsets, 1)
            let itemWidth = max(
                floor(
                    (availableWidth - spacing * CGFloat(max(columns - 1, 0)))
                        / CGFloat(columns) * 100
                ) / 100 - 0.01,
                1
            )
            let targetColumn = (0..<columns).min { lhs, rhs in
                let lhsCenter = sectionInset.left
                    + itemWidth / 2
                    + CGFloat(lhs) * (itemWidth + spacing)
                let rhsCenter = sectionInset.left
                    + itemWidth / 2
                    + CGFloat(rhs) * (itemWidth + spacing)
                return abs(lhsCenter - viewportX) < abs(rhsCenter - viewportX)
            } ?? 0
            // UICollectionViewFlowLayout advances the item row phase once for
            // the scrolling section header. Offset the leading placeholders so
            // the anchored circle still lands in the column under the pinch.
            return (targetColumn - circleIndex % columns + columns + 1) % columns
        }

        private func restore(
            anchor: PinchAnchor,
            in collectionView: UICollectionView
        ) {
            guard let attributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) else {
                return
            }
            collectionView.contentOffset = ExploreGalleryZoomGeometry.anchoredContentOffset(
                itemFrame: attributes.frame,
                itemUnitPoint: anchor.itemUnitPoint,
                viewportPoint: anchor.viewportPoint,
                contentSize: collectionView.collectionViewLayout.collectionViewContentSize,
                viewportSize: collectionView.bounds.size,
                adjustedInsets: collectionView.adjustedContentInset
            )
        }

        private func stepZoom(towardFewerColumns: Bool) -> Bool {
            guard let collectionView else { return false }
            let levels = ExploreGalleryZoomGeometry.columnLevels
            let currentIndex = levels.enumerated().min {
                abs($0.element - columnCount) < abs($1.element - columnCount)
            }?.offset ?? 0
            let targetIndex = towardFewerColumns
                ? max(currentIndex - 1, 0)
                : min(currentIndex + 1, levels.count - 1)
            guard targetIndex != currentIndex else { return false }

            let center = CGPoint(x: collectionView.bounds.midX, y: collectionView.bounds.midY)
            guard let anchor = makeAnchor(at: center, initialColumns: columnCount) else {
                return false
            }
            finishZoom(columns: levels[targetIndex], preserving: anchor)
            return true
        }

        private func updateAccessibility() {
            collectionView?.accessibilityValue = String(
                localized: "\(Int(ExploreGalleryZoomGeometry.nearestColumnLevel(to: columnCount))) columns"
            )
        }

        private static func cardDetail(for columns: CGFloat) -> ExploreGalleryCardDetail {
            if columns >= 4 {
                return .artworkOnly
            }
            if columns >= 2.5 {
                return .title
            }
            return .full
        }
    }
}

/// UIKit normally protects controls such as the search field and header buttons
/// from having their touches cancelled by an enclosing scroll view. On this
/// screen that leaves only the narrow gaps between controls available for
/// vertical scrolling. Let the collection view take over once a tap becomes a
/// drag; ordinary taps still reach the original control.
final class ExploreTouchCancellingCollectionView: UICollectionView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastLaidOutBoundsSize = CGSize.zero

    override func layoutSubviews() {
        let previousSize = lastLaidOutBoundsSize
        super.layoutSubviews()

        let currentSize = bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        lastLaidOutBoundsSize = currentSize
        guard previousSize != currentSize else { return }

        Task { @MainActor [weak self] in
            self?.onBoundsSizeChange?()
        }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }
}

@MainActor
private final class ExploreGalleryHeaderReusableView: UICollectionReusableView {
    private var hostedContentView: (UIView & UIContentView)?

    func configure<Content: View>(with content: Content) {
        let configuration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)

        if let hostedContentView {
            hostedContentView.configuration = configuration
            return
        }

        let contentView = configuration.makeContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostedContentView = contentView
        isAccessibilityElement = false
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
