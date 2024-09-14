//
//  Image+Data.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/14/24.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Image {
    /// Initializes a SwiftUI `Image` from data.
    init?(data: Data?) {
        guard let data = data else { return nil }

        #if canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            self.init(uiImage: uiImage)
        } else {
            return nil
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            self.init(nsImage: nsImage)
        } else {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Asynchronously initializes a SwiftUI `Image` from data.
    static func asyncInit(data: Data?) async -> Image? {
        guard let data = data else {
            return nil
        }

        return await withUnsafeContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let uiImage = UIImage(data: data) {
                    let image = Image(uiImage: uiImage)
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
