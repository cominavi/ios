import Foundation
import XCTest

final class ImageCacheLocalizationTests: XCTestCase {
    func testEveryImageCacheStringHasReviewedCopyInEverySupportedLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ComiNavi/ImageCache.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        XCTAssertFalse(strings.isEmpty)
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            for language in ["ja", "ko", "zh-Hans", "zh-Hant"] {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) localization for \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any]
                )
                XCTAssertEqual(unit["state"] as? String, "translated")
                XCTAssertFalse((unit["value"] as? String ?? "").isEmpty)
            }
        }
    }
}
