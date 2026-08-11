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
            japaneseBundle.localizedString(forKey: "Popular tags", value: nil, table: nil),
            "人気のタグ"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Most-used tags for this day",
                value: nil,
                table: nil
            ),
            "この日に多く使われているタグ"
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
                forKey: "Choose a primary plan",
                value: nil,
                table: nil
            ),
            "メインプランを選択"
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
                forKey: "Your memo is saved after a short pause and when you leave this screen.",
                value: nil,
                table: nil
            ),
            "メモは入力が少し止まったときと、この画面を離れるときに保存します。"
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
    }

    func testNewLocalizationsResolveRepresentativeInterfaceCopy() throws {
        let expectations: [String: [String: String]] = [
            "zh-Hans": [
                "Map": "地图",
                "Explore": "探索",
                "Where Am I": "设置当前位置",
                "Welcome to ComiNavi!": "欢迎来到 ComiNavi！",
                "Find circles. Know where they are.": "找到社团，确认位置。",
                "Login via circle.ms": "使用 Circle.ms 登录",
                "East 1–3": "东1–3馆",
                "Shinagaki": "商品一览",
                "Members and invitations": "成员与邀请",
                "Shared Plans": "共享计划",
                "Circle": "社团",
                "Catalog": "目录",
                "No Shared Plans are available.": "目前没有可显示的共享计划。",
                "Choose a primary plan": "选择主要计划",
                "How to join a plan": "如何加入计划",
                "Join": "加入",
            ],
            "zh-Hant": [
                "Map": "地圖",
                "Explore": "探索",
                "Where Am I": "設定目前位置",
                "Welcome to ComiNavi!": "歡迎來到 ComiNavi！",
                "Find circles. Know where they are.": "尋找社團，確認位置。",
                "Login via circle.ms": "使用 Circle.ms 登入",
                "East 1–3": "東1–3館",
                "Shinagaki": "商品一覽",
                "Members and invitations": "成員與邀請",
                "Shared Plans": "共享計畫",
                "Circle": "社團",
                "Catalog": "目錄",
                "No Shared Plans are available.": "目前沒有可顯示的共享計畫。",
                "Choose a primary plan": "選擇主要計畫",
                "How to join a plan": "如何加入計畫",
                "Join": "加入",
            ],
            "ko": [
                "Map": "지도",
                "Explore": "탐색",
                "Where Am I": "현재 위치 설정",
                "Welcome to ComiNavi!": "ComiNavi에 오신 것을 환영합니다!",
                "Find circles. Know where they are.": "서클을 찾고 위치를 확인하세요.",
                "Login via circle.ms": "Circle.ms로 로그인",
                "East 1–3": "동 1–3홀",
                "Shinagaki": "판매 목록",
                "Members and invitations": "멤버 및 초대",
                "Shared Plans": "공유 플랜",
                "Circle": "서클",
                "Catalog": "카탈로그",
                "No Shared Plans are available.": "현재 표시할 수 있는 공유 플랜이 없습니다.",
                "Choose a primary plan": "기본 플랜 선택",
                "How to join a plan": "플랜 참여 방법",
                "Join": "참여",
            ],
        ]

        for (language, strings) in expectations {
            let bundle = try localizedBundle(for: language)
            for (key, expected) in strings {
                XCTAssertEqual(
                    bundle.localizedString(forKey: key, value: nil, table: nil),
                    expected,
                    "Unexpected \(language) translation for \(key)"
                )
            }
        }
    }

    func testEveryCatalogEntryHasReviewedCopyInEverySupportedLanguage() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 250)

        for language in supportedLanguages {
            let missing = strings.compactMap { key, rawEntry -> String? in
                guard let entry = rawEntry as? [String: Any] else { return key }
                if entry["shouldTranslate"] as? Bool == false {
                    return nil
                }
                guard let localizations = entry["localizations"] as? [String: Any],
                      let localization = localizations[language] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      unit["state"] as? String == "translated",
                      let value = unit["value"] as? String,
                      !value.isEmpty
                else { return key }
                return nil
            }

            XCTAssertEqual(missing, [], "Missing \(language) translations: \(missing)")
        }
    }

    func testJapaneseIsTheProjectDevelopmentLanguage() throws {
        let projectURL = sourceCatalogURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ComiNavi.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("developmentRegion = ja;"))
        XCTAssertFalse(project.contains("developmentRegion = en;"))
        XCTAssertTrue(project.contains("\n\t\t\t\tko,"))
        XCTAssertTrue(project.contains("\n\t\t\t\t\"zh-Hans\","))
        XCTAssertTrue(project.contains("\n\t\t\t\t\"zh-Hant\","))
    }

    func testFormatPlaceholdersMatchSourceKeysInEverySupportedLanguage() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for language in supportedLanguages {
            var mismatches: [String] = []
            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any],
                      let localization = localizations[language] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String
                else { continue }
                if placeholders(in: key) != placeholders(in: value) {
                    mismatches.append(key)
                }
            }

            XCTAssertEqual(
                mismatches,
                [],
                "Format placeholders differ in \(language) for: \(mismatches)"
            )
        }
    }

    func testLocalizedLocationPermissionCopyIsPresent() throws {
        let expectedCopy = [
            "ja": "会場候補を表示するために位置情報を使用します",
            "zh-Hans": "东京国际展览中心展馆",
            "zh-Hant": "東京國際展示場展館",
            "ko": "도쿄 빅사이트",
        ]

        for (language, expected) in expectedCopy {
            let url = sourceCatalogURL
                .deletingLastPathComponent()
                .appending(path: "\(language).lproj/InfoPlist.strings")
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(contents.contains("NSLocationWhenInUseUsageDescription"))
            XCTAssertTrue(contents.contains(expected), "Missing \(language) permission copy")
        }
    }

    private let supportedLanguages = ["ja", "zh-Hans", "zh-Hant", "ko"]

    private func localizedBundle(for language: String) throws -> Bundle {
        let bundles = [Bundle.main] + Bundle.allBundles
        let appBundle = try XCTUnwrap(bundles.first { bundle in
            bundle.bundleURL.pathExtension == "app"
                && bundle.url(forResource: language, withExtension: "lproj") != nil
        })
        return try XCTUnwrap(
            appBundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:))
        )
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
