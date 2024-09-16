//
//  GalleryViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI
import UIKit

class GalleryViewController: UINavigationController {
    var circles: [CirclemsDataSchema.ComiketCircleWC] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        self.setViewControllers([GalleryCollectionViewController(circles: CirclemsDataSource.shared.circles)], animated: false)
    }
}

struct GalleryViewControllerWrappedView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GalleryViewController {
        return GalleryViewController()
    }

    func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {}
}
