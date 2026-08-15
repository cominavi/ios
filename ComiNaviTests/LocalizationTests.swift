@testable import ComiNavi
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testFavoriteMapCopyHasCompleteReviewedTranslations() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = [
            "Add favorites to create a printable map.",
            "Circle list",
            "Color labels",
            "Couldn’t create the favorite map",
            "Event",
            "Favorite circles",
            "Favorite map",
            "Favorites",
            "Label",
            "Labels are shown in the PDF legend and circle list.",
            "Map pages",
            "No favorite circles",
            "Page %lld of %lld",
            "Printable favorite map",
            "Share PDF",
        ]
        let languages = ["ja", "ko", "zh-Hans", "zh-Hant"]

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            for language in languages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) localization for \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "Missing string unit for \(key) in \(language)"
                )
                XCTAssertEqual(unit["state"] as? String, "translated")
                XCTAssertFalse((unit["value"] as? String ?? "").isEmpty)
            }
        }
    }

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
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.": "此 X 账号关注了超过 5,000 人，无法导入。ComiNavi 最多可导入 5,000 个账号",
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
                "This X account follows more than 5,000 people. ComiNavi can import up to 5,000 accounts.": "此 X 帳號關注了超過 5,000 人，無法匯入。ComiNavi 最多可匯入 5,000 個帳號",
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
                      hasReviewedCopy(in: localization)
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
                      let localization = localizations[language] as? [String: Any]
                else { continue }
                if localizedValues(in: localization).contains(where: {
                    placeholders(in: key) != placeholders(in: $0)
                }) {
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
                      let localization = localizations[language] as? [String: Any]
                else { continue }

                for value in localizedValues(in: localization) {
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
            "en": "ComiNavi uses your location in GPS Mode to update your position on the Tokyo Big Sight map. GPS may be inaccurate indoors.",
            "ja": "ComiNaviは、GPSモードで東京ビッグサイトのマップ上の現在地を更新するために位置情報を使用します。屋内ではGPSが不正確になる場合があります。",
            "ko": "ComiNavi는 GPS 모드에서 도쿄 빅사이트 지도상의 현재 위치를 업데이트하기 위해 위치 정보를 사용합니다. 실내에서는 GPS가 부정확할 수 있습니다.",
            "zh-Hans": "ComiNavi 会在 GPS 模式下使用你的位置信息，更新你在 Tokyo Big Sight 地图上的位置。GPS 在室内可能不准确",
            "zh-Hant": "ComiNavi 會在 GPS 模式下使用你的位置資訊，更新你在 Tokyo Big Sight 地圖上的位置。GPS 在室內可能不準確",
        ]

        let appSourceURL = sourceCatalogURL.deletingLastPathComponent()
        let basePlistData = try Data(contentsOf: appSourceURL.appending(path: "Info.plist"))
        let basePlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: basePlistData, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(
            basePlist["NSLocationWhenInUseUsageDescription"] as? String,
            expectedCopy["en"]
        )

        for (language, expected) in expectedCopy {
            let url = appSourceURL
                .appending(path: "\(language).lproj/InfoPlist.strings")
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                contents.contains(
                    "\"NSLocationWhenInUseUsageDescription\" = \"\(expected)\";"
                ),
                "Incorrect \(language) permission copy"
            )
        }
    }

    func testAccountDeletionCopyKeepsCirclemsAccountSeparate() throws {
        let key = "This permanently deletes your ComiNavi account and its data. Your Circle.ms account will not be deleted, even if you connected it to ComiNavi."
        let expectedCopy = [
            "ja": "ComiNaviアカウントとそのデータは完全に削除されます。ComiNaviに連携している場合も、Circle.msアカウントは削除されません。",
            "ko": "ComiNavi 계정과 데이터는 영구적으로 삭제됩니다. ComiNavi에 연동한 경우에도 Circle.ms 계정은 삭제되지 않습니다.",
            "zh-Hans": "这会永久删除你的ComiNavi账户及其数据。即使Circle.ms已连接到ComiNavi，你的Circle.ms账户也不会被删除",
            "zh-Hant": "這會永久刪除你的ComiNavi帳號及其資料。即使Circle.ms已連結至ComiNavi，你的Circle.ms帳號也不會被刪除",
        ]

        for language in supportedLanguages {
            let bundle = try localizedBundle(for: language)
            XCTAssertEqual(
                bundle.localizedString(forKey: key, value: nil, table: nil),
                expectedCopy[language],
                "Account-separation warning is incorrect for \(language)"
            )
        }
    }

    func testAccountDeletionActionsUseUserIntentCopy() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expectedCopy = [
            "Next": [
                "ja": "次へ",
                "ko": "다음",
                "zh-Hans": "下一步",
                "zh-Hant": "下一步",
            ],
            "Delete": [
                "ja": "削除",
                "ko": "삭제",
                "zh-Hans": "删除",
                "zh-Hant": "刪除",
            ],
            "Yes, Delete": [
                "ja": "はい、削除します",
                "ko": "예, 삭제합니다",
                "zh-Hans": "确认删除",
                "zh-Hant": "確認刪除",
            ],
        ]

        for (key, translations) in expectedCopy {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in supportedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any]
                )
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["value"] as? String, translations[language])
            }
        }

        XCTAssertNil(strings["Show final confirmation"])
        XCTAssertNil(strings["System confirmation shown in %lld seconds"])
    }

    private let supportedLanguages = ["ja", "zh-Hans", "zh-Hant", "ko"]

    private let pluralizedKeys = [
        "%@ | %lld blocks",
        "%lld choices",
        "%lld choices need attention",
        "%lld circles",
        "%lld circles have a recorded result",
        "%lld columns",
        "%lld matching circles",
        "%lld table spaces",
        "%lld unread notifications",
        "Affected circles: %lld",
        "Delete available in %lld seconds",
        "Imported circles (%lld)",
        "Next available in %lld seconds",
    ]

    func testPluralEntriesHaveReviewedLocaleForms() throws {
        let data = try Data(contentsOf: sourceCatalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        for key in pluralizedKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing plural entry: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let expectedCategories = [
                "en": ["one", "other"],
                "ja": ["other"],
                "ko": ["other"],
                "zh-Hans": ["other"],
                "zh-Hant": ["other"],
            ]

            for (language, categories) in expectedCategories {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) plural localization for \(key)"
                )
                let variations = try XCTUnwrap(
                    localization["variations"] as? [String: Any],
                    "Missing plural variations for \(language): \(key)"
                )
                let plural = try XCTUnwrap(
                    variations["plural"] as? [String: Any],
                    "Missing plural rule for \(language): \(key)"
                )
                XCTAssertEqual(
                    Set(plural.keys),
                    Set(categories),
                    "Unexpected plural categories for \(language): \(key)"
                )

                for category in categories {
                    let variant = try XCTUnwrap(plural[category] as? [String: Any])
                    let unit = try XCTUnwrap(variant["stringUnit"] as? [String: Any])
                    XCTAssertEqual(unit["state"] as? String, "translated")
                    let value = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertFalse(value.isEmpty)
                    XCTAssertEqual(
                        placeholders(in: key),
                        placeholders(in: value),
                        "Format placeholders differ in \(language) \(category) for: \(key)"
                    )
                }
            }
        }
    }

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

    private func localizedValues(in localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String
        {
            return [value]
        }

        guard let variations = localization["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any]
        else { return [] }

        return plural.values.compactMap { rawVariant in
            guard let variant = rawVariant as? [String: Any],
                  let unit = variant["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String
            else { return nil }
            return value
        }
    }

    private func hasReviewedCopy(in localization: [String: Any]) -> Bool {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return unit["state"] as? String == "translated"
                && unit["value"] as? String != nil
                && !(unit["value"] as? String ?? "").isEmpty
        }

        guard let variations = localization["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any],
              !plural.isEmpty
        else { return false }

        return plural.values.allSatisfy { rawVariant in
            guard let variant = rawVariant as? [String: Any],
                  let unit = variant["stringUnit"] as? [String: Any],
                  unit["state"] as? String == "translated",
                  let value = unit["value"] as? String
            else { return false }
            return !value.isEmpty
        }
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
