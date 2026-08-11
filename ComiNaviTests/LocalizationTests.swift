@testable import ComiNavi
import Foundation
import XCTest

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
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Log out of Circle.ms?",
                value: nil,
                table: nil
            ),
            "Circle.msからログアウトしますか？"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Circle.ms authorization is required for the direct catalog source.",
                value: nil,
                table: nil
            ),
            "Circle.msの直接カタログを利用するには、Circle.msでの認証が必要です。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Cancel", value: nil, table: nil),
            "キャンセル"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Hiragana, katakana, or romaji",
                value: nil,
                table: nil
            ),
            "ひらがな・カタカナ・ローマ字"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Members and invitations",
                value: nil,
                table: nil
            ),
            "メンバーと招待"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Shared Plan notifications",
                value: nil,
                table: nil
            ),
            "共有プランの通知"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Circle added to Shared Plan",
                value: nil,
                table: nil
            ),
            "共有プランにサークルを追加しました"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Shared Plans are read-only",
                value: nil,
                table: nil
            ),
            "共有プランは現在読み取り専用です"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "No Shared Plans are available.",
                value: nil,
                table: nil
            ),
            "現在表示できる共有プランはありません。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "This Shared Plan has no circles.",
                value: nil,
                table: nil
            ),
            "この共有プランにはサークルがありません。"
        )
        XCTAssertFalse(
            japaneseBundle.localizedString(
                forKey: "No Shared Plans are available.",
                value: nil,
                table: nil
            ).contains("作成")
        )
        XCTAssertFalse(
            japaneseBundle.localizedString(
                forKey: "This Shared Plan has no circles.",
                value: nil,
                table: nil
            ).contains("追加")
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Shared Plan editing is not available yet",
                value: nil,
                table: nil
            ),
            "共有プランの編集はまだ利用できません"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Choose removal or the later edit",
                value: nil,
                table: nil
            ),
            "削除するか、後から加えた変更を残すか選択"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Retained operation data reached the 512 KiB safety limit. Export it, then rebase or discard the local branch.",
                value: nil,
                table: nil
            ),
            "保持している変更データが512 KiBの安全上限に達しました。書き出した後、端末の履歴をリベースするか破棄してください。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Plain text only. Unicode characters are edited by scalar position and saved after a short idle pause or when you leave this screen.",
                value: nil,
                table: nil
            ),
            "メモはプレーンテキストです。Unicode文字を正しい位置で扱い、入力が少し止まったとき、またはこの画面を離れるときにまとめて保存します。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Some favorites could not be imported. You can retry them.",
                value: nil,
                table: nil
            ),
            "一部のお気に入りを追加できませんでした。失敗したサークルだけを再試行できます。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Member-entered outcome",
                value: nil,
                table: nil
            ),
            "メンバーが記録した結果"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Live external reports",
                value: nil,
                table: nil
            ),
            "外部からの最新情報"
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
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
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
