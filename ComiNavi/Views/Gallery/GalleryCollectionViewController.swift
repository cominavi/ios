//
//  GalleryCollectionViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import Combine
import CoreGraphics
import SwiftUI
import UIKit

// This title view should consist of two UILabelViews:
// One bold and bigger text for "Circles" title,
// one smaller and lighter text for the subtitle
class GalleryCollectionTitleView: UIView {
    var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline).bold
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = nil
        return label
    }()

    var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = nil
        return label
    }()

    var stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
}

class CircleCollectionViewEmptyCell: UICollectionViewCell {}

class CircleCollectionViewCell: UICollectionViewCell {
    enum Mergability {
        case ineligible
        case mergableLeading
        case mergableTrailing
    }

    private var leftImageView: UIImageView!
    private var rightImageView: UIImageView!

    private var leftImageViewOneImageConstraint: NSLayoutConstraint!
    private var leftImageViewTwoImageConstraint: NSLayoutConstraint!
    private var imageTask: Task<Void, Never>?
    private var representedCircleIDs: [Int] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupImageView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        representedCircleIDs = []
        leftImageView.image = nil
        rightImageView.image = nil
    }

    private func setupImageView() {
        contentView.backgroundColor = .darkGray

        leftImageView = UIImageView()
        leftImageView.contentMode = .scaleAspectFill
        leftImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(leftImageView)

        NSLayoutConstraint.activate([
            leftImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leftImageView.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor)
        ])
        leftImageViewOneImageConstraint = leftImageView.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        leftImageViewTwoImageConstraint = leftImageView.trailingAnchor.constraint(equalTo: contentView.centerXAnchor)

        rightImageView = UIImageView()
        rightImageView.contentMode = .scaleAspectFit
        rightImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rightImageView)

        NSLayoutConstraint.activate([
            rightImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            rightImageView.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor),
            rightImageView.leftAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
    }

    func configure(
        current: CirclemsDataSchema.ComiketCircleWC,
        next: CirclemsDataSchema.ComiketCircleWC?,
        dataSource: CirclemsDataSource
    ) {
        imageTask?.cancel()
        representedCircleIDs = [current.id] + (next.map { [$0.id] } ?? [])
        leftImageView.image = nil
        rightImageView.image = nil

        let expectedIDs = representedCircleIDs
        imageTask = Task { [weak self] in
            let loadedLeftData = await dataSource.getCircleImage(circleId: current.id)
            let loadedRightData: Data?
            if let next {
                loadedRightData = await dataSource.getCircleImage(circleId: next.id)
            } else {
                loadedRightData = nil
            }
            guard !Task.isCancelled else { return }

            let hasNext = next != nil
            let images = await Task.detached(priority: .userInitiated) {
                var leftImage = loadedLeftData.flatMap(UIImage.init(data:))
                var rightImage = loadedRightData.flatMap(UIImage.init(data:))

                if hasNext {
                    leftImage = leftImage.flatMap { Self.imageByAddingMergeEdge(to: $0, onLeft: false) }
                    rightImage = rightImage.flatMap { Self.imageByAddingMergeEdge(to: $0, onLeft: true) }
                }
                return (leftImage, rightImage)
            }.value

            guard !Task.isCancelled, let self, self.representedCircleIDs == expectedIDs else { return }
            self.leftImageView.image = images.0
            self.rightImageView.image = images.1
            self.leftImageViewOneImageConstraint.isActive = next == nil
            self.leftImageViewTwoImageConstraint.isActive = next != nil
        }
    }

    nonisolated private static func imageByAddingMergeEdge(to image: UIImage, onLeft: Bool) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            image.draw(at: .zero)
            let width: CGFloat = 8
            let offset: CGFloat = 7
            let extraTopOffset: CGFloat = onLeft ? 53 : 0
            let x = onLeft ? 0 : image.size.width - width
            let rectangle = CGRect(
                x: x,
                y: offset + extraTopOffset,
                width: width,
                height: image.size.height - 2 * offset - extraTopOffset
            )
            context.cgContext.setFillColor(UIColor(white: 0.8, alpha: 1).cgColor)
            context.cgContext.fill(rectangle)
        }
    }
}

extension CircleCollectionViewCell.Mergability {
    static func from(current: CirclemsDataSchema.ComiketCircleWC, leading: CirclemsDataSchema.ComiketCircleWC?, trailing: CirclemsDataSchema.ComiketCircleWC?) -> CircleCollectionViewCell.Mergability {
        if current.sameCircle(as: leading) { return .mergableLeading }
        if current.sameCircle(as: trailing) { return .mergableTrailing }
        return .ineligible
    }
}

class CircleCollectionViewSectionHeader: UICollectionReusableView {
    var nameLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    var countLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 16.0)
        ])

        addSubview(countLabel)
        // countLabel should be aligned to the right-most edge
        NSLayoutConstraint.activate([
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0)
        ])

        // add a thin material as the background
        let blurEffect = UIBlurEffect(style: .systemThinMaterial)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = self.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)
        sendSubviewToBack(blurView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class GalleryCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private var viewModel: GalleryCollectionViewModel
    private let dataSource: CirclemsDataSource

    private var layout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionHeadersPinToVisibleBounds = true
        return layout
    }()

    private var collectionView: UICollectionView?
    private var searchController: UISearchController = .init()
    private var titleView: GalleryCollectionTitleView = .init()
    private var numberOfColumns: CGFloat = 6
    private var cancellables: Set<AnyCancellable> = []

    init(circles: [CirclemsDataSchema.ComiketCircleWC], dataSource: CirclemsDataSource) {
        self.dataSource = dataSource
        self.viewModel = GalleryCollectionViewModel(
            circles: circles,
            blocks: dataSource.comiket.blocks
        )
        super.init(nibName: nil, bundle: nil)
//        self.viewModel.$circleGroups
//            .sink { [weak self] _ in
//                self?.collectionView?.reloadData()
//                self?.update()
//            }
//            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        guard let collectionView = collectionView else { return }

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(CircleCollectionViewCell.self, forCellWithReuseIdentifier: "CircleCell")
        collectionView.register(CircleCollectionViewEmptyCell.self, forCellWithReuseIdentifier: "CircleEmptyCell")
        collectionView.register(CircleCollectionViewSectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "CircleSectionHeader")
        view.addSubview(collectionView)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        collectionView.backgroundColor = .systemBackground

        self.title = String(localized: "Gallery", comment: "Gallery")
        titleView.titleLabel.text = String(localized: "Gallery", comment: "Gallery")
        self.navigationItem.titleView = titleView

//        // add two right button items to navigation item that decreases/increases the number of columns
//        let decreaseButton = UIBarButtonItem(image: UIImage(systemName: "minus"), style: .plain, target: self, action: #selector(increaseColumns))
//        let increaseButton = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(decreaseColumns))
//        self.navigationItem.rightBarButtonItems = [increaseButton, decreaseButton]

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search...", comment: "Search")
        searchController.searchResultsUpdater = self
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true

        update()
    }

    func update() {
        titleView.subtitleLabel.text = String(
            localized: "\(dataSource.comiket.name) | \(viewModel.circleGroups.count) blocks",
            comment: "Comiket name followed by the number of visible blocks"
        )
    }

//    @objc private func decreaseColumns() {
//        self.numberOfColumns = max(2, numberOfColumns - 1)
//        updateCollectionViewLayout()
//    }
//
//    @objc private func increaseColumns() {
//        self.numberOfColumns = min(6, numberOfColumns + 1)
//        updateCollectionViewLayout()
//    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let circle = viewModel.circleGroups[indexPath.section].unifiedCircles[indexPath.item]
        let hostingController = UIHostingController(
            rootView: CircleDetailView(
                circle: circle.circle,
                dataSource: dataSource
            )
        )

        let destinationVC = UIViewController()

        // Add the hosting controller as a child view controller
        destinationVC.addChild(hostingController)
        destinationVC.view.addSubview(hostingController.view)

        // Set up constraints for the hosting controller's view
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: destinationVC.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: destinationVC.view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: destinationVC.view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: destinationVC.view.bottomAnchor)
        ])

        // Notify the hosting controller that it has been moved to a parent view controller
        hostingController.didMove(toParent: destinationVC)

        navigationController?.pushViewController(destinationVC, animated: true)
    }
}

// - MARK: Collection View Data Source
extension GalleryCollectionViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return viewModel.circleGroups.count
    }

    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        return viewModel.circleGroups.map { $0.block.name }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel.circleGroups[section].unifiedCircles.count
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let safeArea = collectionView.safeAreaInsets.left + collectionView.safeAreaInsets.right
        let width = (collectionView.bounds.width - safeArea) / numberOfColumns

        // Calculate height based on the aspect ratio of 211x300
        let aspectRatio: CGFloat = 300 / 211
        let height = width * aspectRatio

        let unifiedCircles = self.viewModel.circleGroups[indexPath.section].unifiedCircles[indexPath.item]

        if unifiedCircles.selfBeenMerged {
            return .zero
        }

        return unifiedCircles.trailingItemMergable ? CGSize(width: width * 2 - 0.01 * 2, height: height) : CGSize(width: width - 0.01, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let circle = viewModel.circleGroups[indexPath.section].unifiedCircles[indexPath.item]
        if circle.selfBeenMerged {
            return collectionView.dequeueReusableCell(withReuseIdentifier: "CircleEmptyCell", for: indexPath) as! CircleCollectionViewEmptyCell
        }

        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "CircleCell", for: indexPath) as! CircleCollectionViewCell
        var next: CirclemsDataSchema.ComiketCircleWC? = nil
        if circle.trailingItemMergable {
            next = viewModel.circleGroups[indexPath.section].unifiedCircles[indexPath.item + 1].circle
        }
        cell.configure(current: circle.circle, next: next, dataSource: dataSource)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "CircleSectionHeader", for: indexPath) as! CircleCollectionViewSectionHeader
        header.nameLabel.text = viewModel.circleGroups[indexPath.section].block.name
        header.countLabel.text = viewModel.circleGroups[indexPath.section].unifiedCircles.count.string
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        return CGSize(width: collectionView.frame.width, height: 24)
    }
}

// - MARK: Context Menu (Preview)
extension GalleryCollectionViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let unifiedCircles = self.viewModel.circleGroups[indexPath.section].unifiedCircles[indexPath.item]
        let config = UIContextMenuConfiguration(
            identifier: indexPath as NSIndexPath,
            previewProvider: { () -> UIViewController? in
                let hostingController = UIHostingController(rootView: CirclePreviewView(circle: unifiedCircles.circle).padding())
                hostingController.preferredContentSize = CGSize(width: 300, height: 400)
                return hostingController
            },
            actionProvider: { _ in
                self.circleContextMenu(circle: unifiedCircles.circle)
            }
        )

        return config
    }

    private func circleContextMenu(circle: CirclemsDataSchema.ComiketCircleWC) -> UIMenu {
        // Create "Add to Favorites" and "Show in Map"
        let addToFavorites = UIAction(title: String(localized: "Add to Favorites", comment: "Gallery Preview Action: Add to Favorites"), image: UIImage(systemName: "star")) { _ in
            // Add to favorites
        }
        let showInMap = UIAction(title: String(localized: "Show in Map", comment: "Gallery Preview Action: Show in Map"), image: UIImage(systemName: "map")) { _ in
            // Show in map
        }
        return UIMenu(title: String(localized: "Actions", comment: "Gallery Preview Action Title"), children: [addToFavorites, showInMap])
    }

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let vc = animator.previewViewController else { return }

        animator.addCompletion {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
}

// - MARK: Search Controller
extension GalleryCollectionViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController.searchBar.text else { return }
        self.viewModel.setSearchKeyword(text)
        self.collectionView?.reloadData()
    }
}
