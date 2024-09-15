//
//  GalleryViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI
import UIKit

class GalleryViewController: UINavigationController {
    private var galleryCollectionViewController = GalleryCollectionViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        setViewControllers([galleryCollectionViewController], animated: false)
    }
}

struct GalleryViewControllerWrappedView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GalleryViewController {
        return GalleryViewController()
    }

    func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {}
}
