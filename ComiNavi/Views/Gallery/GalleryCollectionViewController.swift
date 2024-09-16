//
//  GalleryCollectionViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import AsyncDisplayKit
import SwiftUI
import UIKit

// This title view should consist of two UILabelViews:
// One bold and bigger text for "Circles" title,
// one smaller and lighter text for the subtitle
class GalleryCollectionTitleView: UIView {
    var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Title"
        return label
    }()

    var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Subtitle"
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

class CircleCollectionViewCellNode: ASCellNode {
    var circle: Circle
    private var imageNode = ASImageNode()
    private var activeCircleId: Int?

    init(circle: Circle) {
        self.circle = circle
        super.init()
        setupImageNode()
    }

    private func setupImageNode() {
        imageNode.backgroundColor = .darkGray
        imageNode.contentMode = .scaleAspectFit
        addSubnode(imageNode)

        // read the image from the local cache in a background thread
        let url = DirectoryManager.shared.cachesFor(comiketId: CirclemsDataSource.shared.comiket.number, .circlems, .images)
            .appendingPathComponent("circles")
            .appendingPathComponent("\(circle.id).png")

        guard let imageData = try? Data(contentsOf: url), let image = UIImage(data: imageData) else { return }

        self.imageNode.image = image
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        return ASRatioLayoutSpec(ratio: 300 / 211, child: imageNode)
    }
}

class CircleCollectionViewSectionHeaderView: UIView {
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

class GalleryCollectionViewController: UIViewController, ASCollectionDelegateFlowLayout {
    var circles: [Circle] = []
    var circleGroups: [CircleBlockGroup] = []

    private var collectionNode: ASCollectionNode!
    private var layout: UICollectionViewFlowLayout! = UICollectionViewFlowLayout()
    private var searchController: UISearchController! = UISearchController()
    private var titleView: GalleryCollectionTitleView!
    private var numberOfColumns: CGFloat = 6

    init(circles: [Circle]) {
        self.circles = circles
        self.circleGroups = CircleBlockGroup.from(circles: circles)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionHeadersPinToVisibleBounds = true

        collectionNode = ASCollectionNode(frame: .zero, collectionViewLayout: layout)
        collectionNode.dataSource = self
        collectionNode.delegate = self

        collectionNode.backgroundColor = .systemBackground

        // make collectionView support safe areas
        collectionNode.view.contentInsetAdjustmentBehavior = .always

        self.title = "Gallery"
        titleView = GalleryCollectionTitleView()
        titleView.titleLabel.text = "Gallery"
        titleView.subtitleLabel.text = "\(CirclemsDataSource.shared.comiket.name) | \(circleGroups.count) blocks"
        self.navigationItem.titleView = titleView

        // add two right button items to navigation item that decreases/increases the number of columns
        let decreaseButton = UIBarButtonItem(image: UIImage(systemName: "minus"), style: .plain, target: self, action: #selector(increaseColumns))
        let increaseButton = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(decreaseColumns))
        self.navigationItem.rightBarButtonItems = [increaseButton, decreaseButton]

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search..."
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true
    }

    @objc private func decreaseColumns() {
        self.numberOfColumns = max(2, numberOfColumns - 1)
        updateCollectionViewLayout()
    }

    @objc private func increaseColumns() {
        self.numberOfColumns = min(10, numberOfColumns + 1)
        updateCollectionViewLayout()
    }

    private func updateCollectionViewLayout() {
        let borderWidth: CGFloat = 0
        let totalSpacing = (numberOfColumns - 1) * borderWidth
        let safeAreaInsets = collectionNode.safeAreaInsets.left + collectionNode.safeAreaInsets.right
        let width = (collectionNode.frame.width - totalSpacing - safeAreaInsets) / numberOfColumns

        // Calculate height based on the aspect ratio of 211x300
        let aspectRatio: CGFloat = 300 / 211
        let height = width * aspectRatio

        UIView.animate(withDuration: 0.3) {
            self.layout.itemSize = CGSize(width: width, height: height)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionViewLayout()
    }

    func collectionNode(_ collectionNode: ASCollectionNode, didSelectItemAt indexPath: IndexPath) {
        let circle = circleGroups[indexPath.section].circles[indexPath.item]
        let hostingController = UIHostingController(rootView: CirclePreviewView(circle: circle))

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
extension GalleryCollectionViewController: ASCollectionDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return circleGroups.count
    }

    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        return circleGroups.map { $0.block.name }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int {
        return circleGroups[section].circles.count
    }

    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt indexPath: IndexPath) -> (() -> ASCellNode) {
        let circle = circleGroups[indexPath.section].circles[indexPath.item]
        return {
            CircleCollectionViewCellNode(circle: circle)
        }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> ASCellNodeBlock {
        let group = circleGroups[indexPath.section]
        return {
            ASCellNode {
                let header = CircleCollectionViewSectionHeaderView()
                header.nameLabel.text = group.block.name
                header.countLabel.text = group.circles.count.string
                return header
            }
        }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        return CGSize(width: collectionNode.frame.width, height: 24)
    }
}

// - MARK: Context Menu (Preview)
extension GalleryCollectionViewController {
    func collectionNode(_ collectionNode: ASCollectionNode, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let circle = self.circleGroups[indexPath.section].circles[indexPath.item]
        let config = UIContextMenuConfiguration(
            identifier: indexPath as NSIndexPath,
            previewProvider: { () -> UIViewController? in
                let hostingController = UIHostingController(rootView: CirclePreviewView(circle: circle))
                hostingController.preferredContentSize = CGSize(width: 300, height: 400)
                return hostingController
            },
            actionProvider: { _ in
                self.circleContextMenu(circle: circle)
            }
        )

        return config
    }

    private func circleContextMenu(circle: Circle) -> UIMenu {
        // Create "Add to Favorites" and "Show in Map"
        let addToFavorites = UIAction(title: "Add to Favorites", image: UIImage(systemName: "star")) { _ in
            // Add to favorites
        }
        let showInMap = UIAction(title: "Show in Map", image: UIImage(systemName: "map")) { _ in
            // Show in map
        }
        return UIMenu(title: "Actions", children: [addToFavorites, showInMap])
    }

    func collectionNode(_ collectionNode: ASCollectionNode, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let vc = animator.previewViewController else { return }

        animator.addCompletion {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
}
