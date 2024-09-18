//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Galvin Gao on 9/18/24.
//

import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Ensure access to extensionItem and itemProvider
        guard
            let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
            let itemProvider = extensionItem.attachments?.first
        else {
            NSLog("[ComiNavi.ShareExtension.ShareViewController] Error accessing extension item or item provider")
            close()
            return
        }

        let urlDataType = UTType.url.identifier
        guard itemProvider.hasItemConformingToTypeIdentifier(urlDataType) else {
            NSLog("[ComiNavi.ShareExtension.ShareViewController] Item provider does not conform to URL data type")
            close()
            return
        }

        itemProvider.loadItem(forTypeIdentifier: urlDataType, options: nil) { item, error in
            if let error = error {
                NSLog("[ComiNavi.ShareExtension.ShareViewController] Error loading item: \(error.localizedDescription)")
                self.close()
                return
            }

            guard let url = item as? URL else {
                print("[ComiNavi.ShareExtension.ShareViewController] Error casting item to URL")
                self.close()
                return
            }

            NSLog("[ComiNavi.ShareExtension.ShareViewController] Received URL: \(url)")
            let username = url.lastPathComponent
            guard !username.isEmpty else {
                NSLog("[ComiNavi.ShareExtension.ShareViewController] Username is empty")
                self.close()
                return
            }

            let circleExtend = try? CirclemsDataSource.shared.sqliteMain.read { db in
                try CirclemsDataSchema.ComiketCircleExtend.fetchOne(db, sql: "SELECT * FROM ComiketCircleExtend WHERE twitterURL = ?", arguments: ["https://twitter.com/\(username)"])
            }

            guard let circleExtend = circleExtend else {
                NSLog("[ComiNavi.ShareExtension.ShareViewController] CircleExtend is nil")
                self.close()
                return
            }
            guard let circle = CirclemsDataSource.shared.circles.first(where: { $0.id == circleExtend.id }) else {
                NSLog("[ComiNavi.ShareExtension.ShareViewController] Circle is nil")
                self.close()
                return
            }

            DispatchQueue.main.async {
                // host the SwiftUI view
                let contentView = UIHostingController(rootView: CirclePreviewView(circle: circle))
                self.addChild(contentView)
                self.view.addSubview(contentView.view)

                // set up constraints
                contentView.view.translatesAutoresizingMaskIntoConstraints = false
                contentView.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
                contentView.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
                contentView.view.leftAnchor.constraint(equalTo: self.view.leftAnchor).isActive = true
                contentView.view.rightAnchor.constraint(equalTo: self.view.rightAnchor).isActive = true
            }

            self.close()
        }
    }

    /// Close the Share Extension
    func close() {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
