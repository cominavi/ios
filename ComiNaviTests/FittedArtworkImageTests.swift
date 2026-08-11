import CoreImage
import SwiftUI
import UIKit
import XCTest
@testable import ComiNavi

@MainActor
final class FittedArtworkImageTests: XCTestCase {
    func testWideArtworkIsFittedOverDimmedEdgeToEdgeBackground() throws {
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 200, height: 100)
        ).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }

        let renderer = ImageRenderer(
            content: FittedArtworkImage(image: Image(uiImage: source))
                .frame(width: 100, height: 100)
        )
        renderer.proposedSize = ProposedViewSize(width: 100, height: 100)
        renderer.scale = 1

        let renderedImage = try XCTUnwrap(renderer.uiImage)
        let foreground = try rgba(in: renderedImage, at: CGPoint(x: 50, y: 50))
        let background = try rgba(in: renderedImage, at: CGPoint(x: 50, y: 10))

        XCTAssertGreaterThan(foreground.red, 0.8)
        XCTAssertLessThan(foreground.green, 0.2)
        XCTAssertLessThan(foreground.blue, 0.2)

        XCTAssertEqual(background.red, background.green, accuracy: 0.08)
        XCTAssertEqual(background.green, background.blue, accuracy: 0.08)
        XCTAssertLessThan(background.red, 0.45)
        XCTAssertGreaterThan(background.alpha, 0.95)
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> RGBA {
        let ciImage = try XCTUnwrap(CIImage(image: image))
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            ciImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return RGBA(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: CGFloat(pixel[3]) / 255
        )
    }
}

private struct RGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}
