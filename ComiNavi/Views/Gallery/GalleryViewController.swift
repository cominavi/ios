//
//  GalleryViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI
import UIKit

class GalleryViewController: UINavigationController {
    var circles: [Circle] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        Task {
            self.circles = await CirclemsDataSource.shared.getCircles()

            DispatchQueue.main.async {
                self.setViewControllers([GalleryCollectionViewController(circles: self.circles)], animated: false)
            }
        }
    }
}

struct GalleryViewControllerWrappedView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GalleryViewController {
        return GalleryViewController()
    }

    func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {}
}
