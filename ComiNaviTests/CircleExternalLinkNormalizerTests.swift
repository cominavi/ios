import XCTest
@testable import ComiNavi

final class CircleExternalLinkNormalizerTests: XCTestCase {
    func testMalformedXHandlesBecomeCanonicalProfiles() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("http://@KiuJony"),
            .init("http://@agets_kurokawa (X)"),
            .init("http://X (Twitter) @shalink_")
        ])

        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://x.com/KiuJony",
            "https://x.com/agets_kurokawa",
            "https://x.com/shalink_"
        ])
        XCTAssertTrue(links.allSatisfy { $0.kind == .xProfile })
    }

    func testTwitterURLsUnifyToXAndDropTrackingQuery() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("https://twitter.com/lirili_vier?t=PWz_x6ezDxDhGNYVWMSJSg&s=09"),
            .init("http://twitter.com/@UnoRyoku")
        ])

        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://x.com/lirili_vier",
            "https://x.com/UnoRyoku"
        ])
    }

    func testEmailMasqueradingAsURLIsNeverReturned() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("http://piisuke9387@icloud.com"),
            .init("http://3k0micos@gmail.com"),
            .init("https://example.com/contact/private@custom-domain.example"),
            .init("mailto:private@example.com")
        ])

        XCTAssertTrue(links.isEmpty)
    }

    func testMultipleLinksAreExtractedNormalizedAndPrioritized() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init(
                "https://example.com?utm_source=c108 "
                    + "https://www.pixiv.net/member.php?id=4403610 "
                    + "https://twitter.com/camekameninn"
            ),
            .init("https://portal.circle.ms/Circle/Index/123", hint: .circlems)
        ])

        XCTAssertEqual(links.map(\.kind), [.xProfile, .pixiv, .website, .circlems])
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://x.com/camekameninn",
            "https://www.pixiv.net/users/4403610",
            "https://example.com",
            "https://portal.circle.ms/Circle/Index/123"
        ])
    }

    func testDuplicateTwitterAndXValuesCollapseAfterNormalization() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("https://twitter.com/example"),
            .init("https://x.com/Example?s=09", hint: .xProfile)
        ])

        XCTAssertEqual(links.map(\.url.absoluteString), ["https://x.com/example"])
    }

    func testLinkPreviewsExposeUsefulAccountAndRecordIdentifiers() throws {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("https://x.com/cominavi_app", hint: .xProfile),
            .init("https://www.pixiv.net/users/4403610", hint: .pixiv),
            .init("https://portal.circle.ms/Circle/Index/12309812", hint: .circlems),
        ])

        XCTAssertEqual(links.map(\.preview), [
            "@cominavi_app",
            "Pixiv ID 4403610",
            "Circle ID 12309812",
        ])
    }

    func testMultipleOfficialCirclemsURLsCollapseToOneRecordRow() {
        let links = CircleExternalLinkNormalizer.links(from: [
            .init("https://webcatalog.circle.ms/Circle/23002117", hint: .circlems),
            .init("https://portal.circle.ms/Circle/Index/23002117", hint: .circlems),
        ])

        XCTAssertEqual(links.map(\.kind), [.circlems])
        XCTAssertEqual(links.map(\.preview), ["Circle ID 23002117"])
    }
}
