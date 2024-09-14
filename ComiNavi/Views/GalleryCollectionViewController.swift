//
//  GalleryCollectionViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI
import UIKit

class CircleCollectionViewCell: UICollectionViewCell {
    private var imageView: UIImageView!

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
            }
        }
    }
}

class CirclesViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var circles: [Circle] = []

    private var collectionView: UICollectionView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4

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

        navigationItem.title = "Circles Gallery"

        Task {
            self.circles = await CirclemsDataSource.shared.getCircles()
            self.collectionView.reloadData()
        }
    }

    // UICollectionViewDataSource methods
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return circles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "CircleCell", for: indexPath) as! CircleCollectionViewCell
        let circle = circles[indexPath.item]
        cell.configure(with: circle)
        return cell
    }

    // UICollectionViewDelegateFlowLayout methods
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let numberOfColumns: CGFloat = 6
        let spacing: CGFloat = 4
        let totalSpacing = (numberOfColumns - 1) * spacing
        let width = (collectionView.bounds.width - totalSpacing) / numberOfColumns

        // Calculate height based on the aspect ratio of 211x300
        let aspectRatio: CGFloat = 300 / 211
        let height = width * aspectRatio

        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let circle = circles[indexPath.item]
        let destinationVC = UIViewController()
        destinationVC.view = UIHostingController(rootView: Text(circle.circleName ?? "")).view
        navigationController?.pushViewController(destinationVC, animated: true)
    }
}

struct CirclesViewControllerWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CirclesViewController {
        let viewController = CirclesViewController()

        return viewController
    }

    func updateUIViewController(_ uiViewController: CirclesViewController, context: Context) {
        // Update the view controller if needed
    }
}

// extension CircleCollectionViewCell {
//    override func addInteraction(_ interaction: UIInteraction) {
//        super.addInteraction(interaction)
//        let contextMenuInteraction = UIContextMenuInteraction(delegate: self)
//        addInteraction(contextMenuInteraction)
//    }
// }

//
// extension CircleCollectionViewCell: UIContextMenuInteractionDelegate {
//    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
//        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
//            UIHostingController(rootView: CirclePreviewView(circle: self.circle))
//        }, actionProvider: { _ in
//            self.circleContextMenu(circle: self.circle)
//        })
//    }
//
//    private func circleContextMenu(circle: Circle) -> UIMenu {
//        // Create your context menu actions here
//        // Example:
//        let renameAction = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
//            // Handle rename action
//        }
//        return UIMenu(title: "", children: [renameAction])
//    }
// }
