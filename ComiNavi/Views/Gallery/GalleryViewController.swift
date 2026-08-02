//
//  GalleryViewController.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/15/24.
//

import SwiftUI
import UIKit

class GalleryViewController: UINavigationController {
    private let dataSource: CirclemsDataSource

    init(dataSource: CirclemsDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let loadingViewController = UIHostingController(rootView: ProgressView("Loading circles…"))
        setViewControllers([loadingViewController], animated: false)

        Task { [weak self] in
            guard let self else { return }
            let circles = await dataSource.getCircles()
            guard !Task.isCancelled else { return }
            self.setViewControllers([
                GalleryCollectionViewController(circles: circles, dataSource: dataSource)
            ], animated: false)
        }
    }
}

struct GalleryViewControllerWrappedView: UIViewControllerRepresentable {
    let dataSource: CirclemsDataSource

    func makeUIViewController(context: Context) -> GalleryViewController {
        GalleryViewController(dataSource: dataSource)
    }

    func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {}
}
