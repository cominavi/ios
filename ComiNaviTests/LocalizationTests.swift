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
                forKey: "Shared Plans are read-only",
                value: nil,
                table: nil
            ),
            "共有プランは現在読み取り専用です"
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
                forKey: "Some favorites could not be imported. You can retry them.",
                value: nil,
                table: nil
            ),
            "一部のお気に入りを追加できませんでした。失敗したサークルだけを再試行できます。"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Plan information",
                value: nil,
                table: nil
            ),
            "プラン情報"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Add member",
                value: nil,
                table: nil
            ),
            "メンバーを追加"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.",
                value: nil,
                table: nil
            ),
            "このXアカウントは5,000人を超えるユーザーをフォローしているため、インポートできません。ComiNaviでインポートできるのは5,000アカウントまでです。"
        )
    }

    func testNotificationCopyHasReviewedTranslations() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expected = [
            "ja": "サークルと買い物を追加しました",
            "ko": "서클과 구매 항목을 추가했습니다",
            "zh-Hans": "已添加社团和购物项",
            "zh-Hant": "已新增社團和購買項目",
        ]
        let entry = try XCTUnwrap(strings["Circle and purchase added"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])

        for (language, expectedValue) in expected {
            let localization = try XCTUnwrap(
                localizations[language] as? [String: Any]
            )
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["state"] as? String, "translated")
            XCTAssertEqual(unit["value"] as? String, expectedValue)
        }
    }

    func testNewLocalizationsResolveRepresentativeInterfaceCopy() throws {
        let expectations: [String: [String: String]] = [
            "zh-Hans": [
                "Map": "地图",
                "Explore": "探索",
                "Where Am I": "设置当前位置",
                "Welcome to ComiNavi!": "欢迎来到 ComiNavi！",
                "Find circles. Know where they are.": "找到社团，确认位置",
                "Login via circle.ms": "使用 Circle.ms 登录",
                "East 1–3": "东1–3馆",
                "Shinagaki": "商品一览",
                "Members and invitations": "成员与邀请",
                "Shared Plans": "共享计划",
                "Circle": "社团",
                "Catalog": "目录",
                "Choose a primary plan": "选择主要计划",
                "How to join a plan": "如何加入计划",
                "Join": "加入",
                "Plan information": "计划信息",
                "Add member": "添加成员",
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.": "此 X 账号关注了超过 5,000 人，无法导入。ComiNavi 最多可导入 5,000 个账号。",
            ],
            "zh-Hant": [
                "Map": "地圖",
                "Explore": "探索",
                "Where Am I": "設定目前位置",
                "Welcome to ComiNavi!": "歡迎來到 ComiNavi！",
                "Find circles. Know where they are.": "尋找社團，確認位置",
                "Login via circle.ms": "使用 Circle.ms 登入",
                "East 1–3": "東1–3館",
                "Shinagaki": "商品一覽",
                "Members and invitations": "成員與邀請",
                "Shared Plans": "共享計畫",
                "Circle": "社團",
                "Catalog": "目錄",
                "Choose a primary plan": "選擇主要計畫",
                "How to join a plan": "如何加入計畫",
                "Join": "加入",
                "Plan information": "計畫資訊",
                "Add member": "新增成員",
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.": "此 X 帳號關注了超過 5,000 人，無法匯入。ComiNavi 最多可匯入 5,000 個帳號。",
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
                "Choose a primary plan": "기본 플랜 선택",
                "How to join a plan": "플랜 참여 방법",
                "Join": "참여",
                "Plan information": "플랜 정보",
                "Add member": "멤버 추가",
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.": "이 X 계정은 5,000명 넘게 팔로우하고 있어 가져올 수 없습니다. ComiNavi에서는 최대 5,000개의 계정만 가져올 수 있습니다.",
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
        XCTAssertNil(strings["Check now"], "Removed UI labels must not leave stale i18n keys")

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

    func testLocalizedDayLabelDoesNotDuplicateDayNumber() throws {
        let day = 1
        let expectations = [
            "ja": "1日目",
            "ko": "1일차",
            "zh-Hans": "第1天",
            "zh-Hant": "第1天",
        ]

        for (language, expected) in expectations {
            let bundle = try localizedBundle(for: language)
            let localized = String(
                localized: "Day \(day)",
                bundle: bundle,
                locale: Locale(identifier: language)
            )

            XCTAssertEqual(localized, expected, "Unexpected day label in \(language)")
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

    func testChineseInterfaceStyleAndTerminologyRules() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let protectedNames = [
            "Tokyo Big Sight",
            "Comic Market",
            "Comiket",
            "Comike Web Catalog",
            "Cosplay",
            "FamilyMart",
            "Lawson",
            "7-Eleven",
            "Daily Yamazaki",
            "Ministop",
            "Seven Bank",
            "Pixiv",
            "Google",
        ]
        let expectedTerms = [
            "ATM available": ["zh-Hans": "有ATM", "zh-Hant": "有ATM"],
            "AM Entry": ["zh-Hans": "上午入场", "zh-Hant": "上午入場"],
            "Beginner guide in Simplified Chinese": [
                "zh-Hans": "简体中文新手指南",
                "zh-Hant": "簡體中文初學者指南",
            ],
            "PM Entry": ["zh-Hans": "下午入场", "zh-Hant": "下午入場"],
            "Empty text": ["zh-Hans": "空文本", "zh-Hant": "空文本"],
            "Event day": ["zh-Hans": "举办日", "zh-Hant": "舉辦日期"],
            "Galleria": ["zh-Hans": "连廊", "zh-Hant": "連廊"],
            "Import": ["zh-Hans": "导入", "zh-Hant": "匯入"],
            "Official beginner guide": [
                "zh-Hans": "官方新手指南",
                "zh-Hant": "官方初學者指南",
            ],
            "Owner": ["zh-Hans": "所有者", "zh-Hant": "所有者"],
            "Profile": ["zh-Hans": "我", "zh-Hant": "我"],
            "Match all": ["zh-Hans": "匹配全部", "zh-Hant": "匹配全部"],
            "Match any": ["zh-Hans": "匹配任一项", "zh-Hant": "匹配任一項"],
            "Match tags": ["zh-Hans": "匹配标签", "zh-Hant": "匹配標籤"],
            "Possible match": ["zh-Hans": "可能匹配", "zh-Hant": "可能匹配"],
            "Tag matching": ["zh-Hans": "标签匹配", "zh-Hant": "標籤匹配"],
            "Unmatched": ["zh-Hans": "未匹配", "zh-Hant": "未匹配"],
        ]

        for language in ["zh-Hans", "zh-Hant"] {
            var trailingFullStops: [String] = []
            var alteredNames: [String] = []
            var bannedTerms: [String] = []

            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any],
                      let localization = localizations[language] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String
                else { continue }

                if value.hasSuffix("。") { trailingFullStops.append(key) }
                if value.contains("先生")
                    || value.contains("老板")
                    || value.contains("老闆")
                    || value.contains("业主")
                    || value.contains("業主")
                    || value.contains("擁有者")
                    || value.contains("课文")
                    || value.contains("課文")
                {
                    bannedTerms.append(key)
                }
                for name in protectedNames
                where key.localizedCaseInsensitiveContains(name)
                    && !value.contains(name)
                {
                    alteredNames.append(key)
                }
            }

            XCTAssertEqual(trailingFullStops, [], "Trailing Chinese full stops in \(language)")
            XCTAssertEqual(alteredNames, [], "Altered protected names in \(language)")
            XCTAssertEqual(bannedTerms, [], "Disallowed Chinese terminology in \(language)")

            for (key, localizedValues) in expectedTerms {
                let entry = try XCTUnwrap(strings[key] as? [String: Any])
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
                let localization = try XCTUnwrap(localizations[language] as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["value"] as? String, localizedValues[language])
            }
        }
    }

    func testLocalizedLocationPermissionCopyIsPresent() throws {
        let expectedCopy = [
            "ja": "会場候補を表示するために位置情報を使用します",
            "zh-Hans": "Tokyo Big Sight 展馆",
            "zh-Hant": "Tokyo Big Sight 展館",
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
