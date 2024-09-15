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

class GalleryCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    var circles: [CircleBlockGroup] = []

    private var collectionView: UICollectionView!
    private var layout: UICollectionViewFlowLayout! = UICollectionViewFlowLayout()
    private var searchController: UISearchController! = UISearchController()
    private var titleView: GalleryCollectionTitleView!

    override func viewDidLoad() {
        super.viewDidLoad()

        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(CircleCollectionViewCell.self, forCellWithReuseIdentifier: "CircleCell")
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
        titleView.subtitleLabel.text = "\(CirclemsDataSource.shared.comiket.name) | \(circles.count) circles"
        self.navigationItem.titleView = titleView

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search..."
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true

        Task {
            let circles = await CirclemsDataSource.shared.getCircles()
            self.circles = CircleBlockGroup.from(circles: circles)
            self.collectionView.reloadData()

            titleView.subtitleLabel.text = "\(CirclemsDataSource.shared.comiket.name) | \(circles.count) circles"
        }
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
        let circle = circles[indexPath.section].circles[indexPath.item]
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

extension GalleryCollectionViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return circles.count
    }

    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        return circles.map { $0.block.name }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return circles[section].circles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "CircleCell", for: indexPath) as! CircleCollectionViewCell
        let circle = circles[indexPath.section].circles[indexPath.item]
        cell.configure(with: circle)
        return cell
    }
}

// - MARK: Context Menu (Preview)
extension GalleryCollectionViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let circle = self.circles[indexPath.section].circles[indexPath.item]
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
