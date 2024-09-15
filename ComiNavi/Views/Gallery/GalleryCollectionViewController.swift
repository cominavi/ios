//
//  GalleryCollectionViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

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

class CircleCollectionViewCell: UICollectionViewCell {
    private var imageView: UIImageView!
    private var activeCircleId: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupImageView()
    }

    private func setupImageView() {
        contentView.backgroundColor = .darkGray

        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor)
        ])
    }

    func configure(with circle: Circle) {
        DispatchQueue.global(qos: .userInitiated).async {
            // read the image from the local cache in a background thread
            let url = DirectoryManager.shared.cachesFor(comiketId: CirclemsDataSource.shared.comiket.number, .circlems, .images)
                .appendingPathComponent("circles")
                .appendingPathComponent("\(circle.id).png")

            guard let imageData = try? Data(contentsOf: url), let image = UIImage(data: imageData) else { return }

            // update the UI on the main thread
            DispatchQueue.main.async {
                self.imageView.image = image
                self.activeCircleId = circle.id
            }
        }
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
    var circleGroups: [CircleBlockGroup] = []

    private var collectionView: UICollectionView!
    private var layout: UICollectionViewFlowLayout! = UICollectionViewFlowLayout()
    private var searchController: UISearchController! = UISearchController()
    private var titleView: GalleryCollectionTitleView!

    init(circles: [Circle]) {
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

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(CircleCollectionViewCell.self, forCellWithReuseIdentifier: "CircleCell")
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

        self.title = "Gallery"
        titleView = GalleryCollectionTitleView()
        titleView.titleLabel.text = "Gallery"
        titleView.subtitleLabel.text = "\(CirclemsDataSource.shared.comiket.name) | \(circleGroups.count) circles"
        self.navigationItem.titleView = titleView

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search..."
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true
    }

    private func updateCollectionViewLayout() {
        let numberOfColumns: CGFloat = 6
        let borderWidth: CGFloat = 0
        let totalSpacing = (numberOfColumns - 1) * borderWidth
        let width = (collectionView.bounds.width - totalSpacing) / numberOfColumns

        // Calculate height based on the aspect ratio of 211x300
        let aspectRatio: CGFloat = 300 / 211
        let height = width * aspectRatio

        layout.itemSize = CGSize(width: width, height: height)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionViewLayout()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let circle = circleGroups[indexPath.section].circles[indexPath.item]
        let hostingController = UIHostingController(rootView: Text(circle.circleName ?? ""))

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

// - MARK: State Restoration
extension GalleryCollectionViewController {
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        // Save the first visible circle ID
        if let indexPath = collectionView.indexPathsForVisibleItems.first {
            let circle = circleGroups[indexPath.section].circles[indexPath.item]
            coder.encode(circle.id, forKey: "firstVisibleCircleId")
            print("Saving circle with ID: \(circle.id)")
        }
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)
        // Restore the first visible circle ID
        let circleId = coder.decodeInteger(forKey: "firstVisibleCircleId")
        print("Restoring circle with ID: \(circleId)")
        var foundSectionIndex, foundItemIndex: Int?
        for (sectionIndex, group) in circleGroups.enumerated() {
            if let index = group.circles.firstIndex(where: { $0.id == circleId }) {
                foundSectionIndex = sectionIndex
                foundItemIndex = index
                break
            }
        }

        if let foundSectionIndex = foundSectionIndex, let foundItemIndex = foundItemIndex {
            collectionView.scrollToItem(at: IndexPath(item: foundItemIndex, section: foundSectionIndex), at: .top, animated: false)
        }
    }
}

// - MARK: Collection View Data Source
extension GalleryCollectionViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return circleGroups.count
    }

    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        return circleGroups.map { $0.block.name }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return circleGroups[section].circles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "CircleCell", for: indexPath) as! CircleCollectionViewCell
        let circle = circleGroups[indexPath.section].circles[indexPath.item]
        cell.configure(with: circle)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "CircleSectionHeader", for: indexPath) as! CircleCollectionViewSectionHeader
        header.nameLabel.text = circleGroups[indexPath.section].block.name
        header.countLabel.text = circleGroups[indexPath.section].circles.count.string
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        return CGSize(width: collectionView.frame.width, height: 24)
    }
}

// - MARK: Context Menu (Preview)
extension GalleryCollectionViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
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

    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let vc = animator.previewViewController else { return }

        animator.addCompletion {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
}
