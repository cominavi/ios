import SwiftUI
import UIKit
import XCTest

@testable import ComiNavi

final class CircleDetailExternalLinksRowTests: XCTestCase {
    @MainActor
    func testFittingBadgesDoNotBounceHorizontally() async throws {
        let hosted = try await hostedScrollView(
            links: makeLinks(count: 2),
            width: 240
        )
        defer { restoreWindow(after: hosted) }

        XCTAssertLessThanOrEqual(
            hosted.scrollView.contentSize.width,
            hosted.scrollView.bounds.width
        )
        XCTAssertFalse(hosted.scrollView.alwaysBounceHorizontal)
    }

    @MainActor
    func testOverflowingBadgesRemainHorizontallyScrollable() async throws {
        let hosted = try await hostedScrollView(
            links: makeLinks(count: 8),
            width: 160
        )
        defer { restoreWindow(after: hosted) }

        XCTAssertGreaterThan(
            hosted.scrollView.contentSize.width,
            hosted.scrollView.bounds.width
        )
        XCTAssertTrue(hosted.scrollView.isScrollEnabled)
    }

    @MainActor
    private func hostedScrollView(
        links: [CircleExternalLink],
        width: CGFloat
    ) async throws -> (
        window: UIWindow,
        previousKeyWindow: UIWindow?,
        scrollView: UIScrollView
    ) {
        let host = UIHostingController(
            rootView: CircleDetailExternalLinksRowTestHost(links: links)
        )
        let frame = CGRect(x: 0, y: 0, width: width, height: 48)
        let window: UIWindow
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        let previousKeyWindow = windowScene?.windows.first(where: \.isKeyWindow)
        if let windowScene {
            window = UIWindow(windowScene: windowScene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        let scrollViews = descendants(of: UIScrollView.self, in: host.view)
        let scrollView = try XCTUnwrap(scrollViews.first)
        scrollView.layoutIfNeeded()
        return (window, previousKeyWindow, scrollView)
    }

    @MainActor
    private func restoreWindow(
        after hosted: (
            window: UIWindow,
            previousKeyWindow: UIWindow?,
            scrollView: UIScrollView
        )
    ) {
        hosted.window.isHidden = true
        hosted.previousKeyWindow?.makeKey()
    }

    private func makeLinks(count: Int) -> [CircleExternalLink] {
        (0 ..< count).map { index in
            CircleExternalLink(
                kind: .website,
                url: URL(string: "https://example.com/\(index)")!
            )
        }
    }

    @MainActor
    private func descendants<ViewType: UIView>(
        of type: ViewType.Type,
        in view: UIView
    ) -> [ViewType] {
        view.subviews.flatMap { child in
            let childMatches = (child as? ViewType).map { [$0] } ?? []
            return childMatches + descendants(of: type, in: child)
        }
    }
}
