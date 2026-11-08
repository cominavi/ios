import SwiftUI
import UIKit
import XCTest

@testable import ComiNavi

/// The external links row is a flow layout of chips. It wraps onto more lines
/// instead of scrolling sideways, so every link stays visible.
final class CircleDetailExternalLinksRowTests: XCTestCase {
    @MainActor
    func testFittingChipsStayOnOneLine() {
        let oneLink = fittingSize(links: makeLinks(count: 1), width: 320)
        let twoLinks = fittingSize(links: makeLinks(count: 2), width: 320)

        XCTAssertLessThanOrEqual(twoLinks.width, 320)
        XCTAssertEqual(twoLinks.height, oneLink.height, accuracy: 0.5)
    }

    @MainActor
    func testOverflowingChipsWrapWithinTheOfferedWidth() {
        let oneLink = fittingSize(links: makeLinks(count: 1), width: 160)
        let manyLinks = fittingSize(links: makeLinks(count: 8), width: 160)

        XCTAssertLessThanOrEqual(manyLinks.width, 160.5)
        XCTAssertGreaterThan(manyLinks.height, oneLink.height * 2)
    }

    @MainActor
    private func fittingSize(links: [CircleExternalLink], width: CGFloat) -> CGSize {
        let host = UIHostingController(
            rootView: CircleDetailExternalLinksRowTestHost(links: links)
        )
        return host.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
    }

    private func makeLinks(count: Int) -> [CircleExternalLink] {
        (0 ..< count).map { index in
            CircleExternalLink(
                kind: .website,
                url: URL(string: "https://example.com/\(index)")!
            )
        }
    }
}
