import UIKit
import XCTest
@testable import ComiNavi

final class ProfilePresentationTests: XCTestCase {
    func testCirclemsIdentityDoesNotExposeProductionEnvironmentLabel() {
        let identity = CominaviProfileIdentity(
            provider: "circlems",
            environment: "production",
            providerUserID: "42"
        )

        XCTAssertEqual(identity.profileDisplayDetail, "連携済み")
        XCTAssertFalse(identity.profileDisplayDetail.localizedCaseInsensitiveContains("production"))
    }

    func testAvatarProcessorCropsLandscapeImageToBoundedSquareJPEG() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 800)).image {
            UIColor.systemPink.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 800, y: 0, width: 800, height: 800))
        }

        let data = try XCTUnwrap(
            AvatarImageProcessor.squareJPEGData(from: source, maxPixelSize: 512)
        )
        let result = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(result.size.width, 512, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 512, accuracy: 0.5)
    }
}
