import Foundation
import XCTest
@testable import ComiNavi

final class LocalizationTests: XCTestCase {
    func testJapaneseLocalizationResolvesRepresentativeInterfaceCopy() throws {
        let bundles = [Bundle.main] + Bundle.allBundles
        let appBundle = try XCTUnwrap(bundles.first { bundle in
            bundle.bundleURL.pathExtension == "app"
                && bundle.url(forResource: "ja", withExtension: "lproj") != nil
        })
        let japaneseBundle = try XCTUnwrap(
            appBundle.url(forResource: "ja", withExtension: "lproj").flatMap(Bundle.init(url:))
        )

        XCTAssertEqual(japaneseBundle.localizedString(forKey: "Map", value: nil, table: nil), "地図")
        XCTAssertEqual(japaneseBundle.localizedString(forKey: "Explore", value: nil, table: nil), "探す")
        XCTAssertEqual(japaneseBundle.localizedString(forKey: "Where Am I", value: nil, table: nil), "現在地を設定")
        XCTAssertEqual(japaneseBundle.localizedString(forKey: "East 1–3", value: nil, table: nil), "東1–3ホール")
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Welcome to ComiNavi!",
                value: nil,
                table: nil
            ),
            "コミナビへようこそ！"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Crawl data", value: nil, table: nil),
            "クロールデータ"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Shinagaki", value: nil, table: nil),
            "お品書き"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Latest shinagaki",
                value: nil,
                table: nil
            ),
            "お品書きの新着順"
        )
    }

    func testEveryCatalogEntryHasReviewedJapaneseCopy() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 250)

        let missingJapanese = strings.compactMap { key, rawEntry -> String? in
            guard let entry = rawEntry as? [String: Any] else { return key }
            if entry["shouldTranslate"] as? Bool == false {
                return nil
            }
            guard let localizations = entry["localizations"] as? [String: Any],
                  let japanese = localizations["ja"] as? [String: Any],
                  let unit = japanese["stringUnit"] as? [String: Any],
                  unit["state"] as? String == "translated",
                  let value = unit["value"] as? String,
                  !value.isEmpty
            else { return key }
            return nil
        }

        XCTAssertEqual(missingJapanese, [], "Missing Japanese translations: \(missingJapanese)")
    }

    func testJapaneseIsTheProjectDevelopmentLanguage() throws {
        let projectURL = sourceCatalogURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ComiNavi.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("developmentRegion = ja;"))
        XCTAssertFalse(project.contains("developmentRegion = en;"))
    }

    func testJapaneseFormatPlaceholdersMatchSourceKeys() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var mismatches: [String] = []

        for (key, rawEntry) in strings {
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let japanese = localizations["ja"] as? [String: Any],
                  let unit = japanese["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String
            else { continue }
            if placeholders(in: key) != placeholders(in: value) {
                mismatches.append(key)
            }
        }

        XCTAssertEqual(mismatches, [], "Format placeholders differ for: \(mismatches)")
    }

    func testJapaneseLocationPermissionCopyIsPresent() throws {
        let url = sourceCatalogURL
            .deletingLastPathComponent()
            .appending(path: "ja.lproj/InfoPlist.strings")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(contents.contains("NSLocationWhenInUseUsageDescription"))
        XCTAssertTrue(contents.contains("会場候補を表示するために位置情報を使用します"))
    }

    private var sourceCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ComiNavi/Localizable.xcstrings")
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|f|@)"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return value[range].replacingOccurrences(
                of: #"^%\d+\$"#,
                with: "%",
                options: .regularExpression
            )
        }
        .sorted()
    }
}
