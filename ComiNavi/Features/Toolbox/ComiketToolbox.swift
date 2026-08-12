import Foundation
import Observation

struct ComiketToolboxResource: Identifiable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case live
        case planning
        case venue
        case travel
        case safety
        case international

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .live: "Live updates"
            case .planning: "Plan your day"
            case .venue: "At Tokyo Big Sight"
            case .travel: "Getting there"
            case .safety: "Weather and safety"
            case .international: "International visitors"
            }
        }

        var icon: String {
            switch self {
            case .live: "radio-tower"
            case .planning: "list"
            case .venue: "building-2"
            case .travel: "navigation"
            case .safety: "briefcase-medical"
            case .international: "globe"
            }
        }
    }

    enum Authority: String, Sendable {
        case comiket
        case circlems
        case bigSight
        case transitOperator
        case publicAgency

        var label: LocalizedStringResource {
            switch self {
            case .comiket: "Comiket official"
            case .circlems: "Circle.ms official"
            case .bigSight: "Tokyo Big Sight official"
            case .transitOperator: "Transit operator"
            case .publicAgency: "Public agency"
            }
        }
    }

    let id: String
    let category: Category
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let authority: Authority
    let icon: String
    let url: URL
    let searchTerms: String

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedQuery.isEmpty else { return true }

        let searchableText = [
            String(localized: title),
            String(localized: summary),
            String(localized: authority.label),
            searchTerms,
        ]
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return searchableText.localizedStandardContains(normalizedQuery)
    }
}

struct ComiketToolboxSection: Identifiable, Sendable {
    let category: ComiketToolboxResource.Category
    let resources: [ComiketToolboxResource]

    var id: ComiketToolboxResource.Category { category }
}

enum ComiketToolboxCatalog {
    static let venueMapsURL = makeURL(
        "https://maps.apple.com/?daddr=Tokyo+Big+Sight,+3-11-1+Ariake,+Koto+City,+Tokyo&dirflg=r"
    )

    static let resources: [ComiketToolboxResource] = [
        resource(
            "comiket-x",
            .live,
            "Official Comiket X",
            "Latest announcements and same-day changes from the Comic Market Committee.",
            .comiket,
            "radio-tower",
            "https://x.com/comiketofficial",
            "twitter sns 公式 当日 最新 comiketofficial"
        ),
        resource(
            "international-x",
            .live,
            "International Comiket X",
            "English-language notices for international participants.",
            .comiket,
            "globe",
            "https://x.com/comiket_intl",
            "twitter english overseas 英語 海外 comiket_intl"
        ),
        resource(
            "cosplay-x",
            .live,
            "Official cosplay X",
            "Changing-room, cosplay-area, and photography updates.",
            .comiket,
            "drama",
            "https://x.com/comiket_cosplay",
            "twitter cosplay コスプレ 撮影 更衣室 comiket_cosplay"
        ),
        resource(
            "comiket-web",
            .live,
            "Official Comiket website",
            "Formal announcements, revisions, and links for the current event.",
            .comiket,
            "globe",
            "https://www.comiket.co.jp/",
            "ホームページ web news お知らせ 更新"
        ),
        resource(
            "circlems-x",
            .live,
            "Circle.ms X",
            "Service information and updates for Comike Web Catalog.",
            .circlems,
            "at-sign",
            "https://x.com/circlems",
            "twitter webcatalog web catalog サークルエムエス 障害"
        ),
        resource(
            "c108-overview",
            .planning,
            "C108 event overview",
            "Dates, hours, halls, transport guidance, and event-specific changes.",
            .comiket,
            "calendar-days",
            "https://www.comiket.co.jp/info-a/C108/C108Info.html",
            "開催概要 時間 ホール 日程 交通"
        ),
        resource(
            "c108-entry",
            .planning,
            "Admission and wristbands",
            "Entry types, required credentials, exchange times, and admission schedule.",
            .comiket,
            "door-open",
            "https://www.comiket.co.jp/info-a/C108/C108EntryTicket2.html",
            "ticket チケット リストバンド 入場 午前 午後 アーリー"
        ),
        resource(
            "c108-notes",
            .planning,
            "Catalog rules and notices (PDF)",
            "The full official rules and event-day notes participants are expected to read.",
            .comiket,
            "file-text",
            "https://www.comiket.co.jp/info-a/C108/C108CtlgNotes.pdf",
            "catalog notes rules 諸注意 カタログ ルール 禁止事項 pdf"
        ),
        resource(
            "beginner-guide",
            .planning,
            "Official beginner guide",
            "How to prepare, what to bring, how to read placements, and day-of etiquette.",
            .comiket,
            "info",
            "https://harenohi.comiket.co.jp/index.php/beginnersguide/generals/",
            "初心者 guide 持ち物 服装 マナー 配置 調べ方"
        ),
        resource(
            "web-catalog",
            .planning,
            "Comike Web Catalog",
            "Search circles, review cuts, and check official catalog data.",
            .circlems,
            "search",
            "https://webcatalog.circle.ms/",
            "circle search catalog サークル検索 カット 配置"
        ),
        resource(
            "c108-circle-maps",
            .planning,
            "Official C108 circle maps",
            "Download the official hall and circle-space maps for offline reference.",
            .comiket,
            "map",
            "https://www.comiket.co.jp/info-a/C108/C108CtlgMap.html",
            "地図 map offline pdf サークルスペース ホール"
        ),
        resource(
            "c108-food",
            .venue,
            "C108 food and drink",
            "Current catering, restaurant, shop, and drink availability by area.",
            .comiket,
            "shopping-cart",
            "https://www.comiket.co.jp/info-a/C108/C108Food.html",
            "food drink restaurant convenience store フード 飲食 コンビニ 水分"
        ),
        resource(
            "big-sight-floor-maps",
            .venue,
            "Tokyo Big Sight floor maps",
            "Official building-level maps for facilities, toilets, elevators, and services.",
            .bigSight,
            "map",
            "https://www.bigsight.jp/visitor/floormap/",
            "floor map toilet elevator フロアマップ トイレ エレベーター"
        ),
        resource(
            "big-sight-services",
            .venue,
            "Venue services directory",
            "Official directory for food, delivery, information desks, and visitor services.",
            .bigSight,
            "building-2",
            "https://www.bigsight.jp/visitor/services/",
            "service information desk 宅配 案内所 サービス"
        ),
        resource(
            "big-sight-lockers",
            .venue,
            "Lockers and luggage storage",
            "Locker locations, sizes, prices, and staffed luggage options.",
            .bigSight,
            "database",
            "https://www.bigsight.jp/visitor/services/locker.html",
            "locker baggage luggage 荷物 預かり コインロッカー"
        ),
        resource(
            "big-sight-accessibility",
            .venue,
            "Accessibility at Big Sight",
            "Wheelchair loans, accessible toilets, elevators, and facility information.",
            .bigSight,
            "person-standing",
            "https://www.bigsight.jp/visitor/services/accessibility.html",
            "accessibility wheelchair accessible toilet バリアフリー 車椅子 オストメイト"
        ),
        resource(
            "big-sight-wifi",
            .venue,
            "Free Wi-Fi at Big Sight",
            "Current OpenRoaming registration and coverage information.",
            .bigSight,
            "radio-tower",
            "https://www.bigsight.jp/visitor/services/wi-fi.html",
            "wifi wi-fi internet openroaming 通信 無料"
        ),
        resource(
            "lost-and-found",
            .venue,
            "Comiket lost and found",
            "Current counters, collection times, and post-event contact rules.",
            .comiket,
            "search",
            "https://www.comiket.co.jp/info-a/LostsAndFounds.html",
            "lost found lost property 遺失物 落とし物 忘れ物"
        ),
        resource(
            "cosplay-guide",
            .venue,
            "Cosplay and photography rules",
            "Changing rooms, registration, areas, props, costumes, and consent rules.",
            .comiket,
            "drama",
            "https://www.comiket.co.jp/info-p/",
            "cosplay photo camera コスプレ 撮影 更衣室 衣装"
        ),
        resource(
            "big-sight-access",
            .travel,
            "Official Big Sight access guide",
            "Rail, BRT, bus, airport, and walking access from nearby stations.",
            .bigSight,
            "navigation",
            "https://www.bigsight.jp/visitor/access/",
            "access train bus rail transit アクセス 電車 バス 駅"
        ),
        resource(
            "rinkai-line",
            .travel,
            "Rinkai Line schedules",
            "Official service notices and schedules for Kokusai-tenjijo Station.",
            .transitOperator,
            "calendar-clock",
            "https://www.twr.co.jp/route/tabid/102/Default.aspx",
            "rinkai twr 国際展示場 りんかい線 時刻表 臨時ダイヤ"
        ),
        resource(
            "yurikamome-c108",
            .travel,
            "Yurikamome C108 timetable",
            "The operator's special event timetable for August 15–16.",
            .transitOperator,
            "calendar-clock",
            "https://www.yurikamome.co.jp/company/news/bbee2796dd59429f6aa22fb274f5ace8_1.pdf",
            "yurikamome 東京ビッグサイト駅 ゆりかもめ 時刻表 臨時ダイヤ pdf"
        ),
        resource(
            "tokyo-brt-c108",
            .travel,
            "Tokyo BRT C108 extra service",
            "Temporary extra service between Shimbashi and Kokusai-tenjijo.",
            .transitOperator,
            "calendar-clock",
            "https://tokyo-brt.co.jp/caution/547",
            "brt 新橋 国際展示場 臨時便 バス"
        ),
        resource(
            "toei-bus",
            .travel,
            "Toei Bus live information",
            "Live service and arrival information for Tokyo metropolitan buses.",
            .transitOperator,
            "radio-tower",
            "https://tobus.jp/",
            "toei bus 都営バス 運行情報 到着"
        ),
        resource(
            "comiket-heatstroke",
            .safety,
            "Official C108 heatstroke guidance",
            "Hydration, rest, cooling, warning signs, and C108-specific precautions.",
            .comiket,
            "briefcase-medical",
            "https://www.comiket.co.jp/info-a/Heatstroke.html",
            "heat heatstroke hydration cooling 熱中症 水分 塩分 冷却 休憩"
        ),
        resource(
            "jma-tokyo-weather",
            .safety,
            "Tokyo weather forecast",
            "The Japan Meteorological Agency's current forecast for the Tokyo area.",
            .publicAgency,
            "sparkles",
            "https://www.data.jma.go.jp/multi/yoho/yoho_detail.html?code=130010&lang=jp",
            "jma weather rain temperature 気象庁 天気 雨 気温"
        ),
        resource(
            "environment-wbgt",
            .safety,
            "Tokyo heat index (WBGT)",
            "Current and forecast heat-risk levels from Japan's Ministry of the Environment.",
            .publicAgency,
            "triangle-alert",
            "https://www.wbgt.env.go.jp/sp/wbgt_data.php?region=03&tab=td",
            "wbgt heat alert 暑さ指数 環境省 熱中症警戒アラート"
        ),
        resource(
            "big-sight-first-aid",
            .safety,
            "First aid and AED information",
            "Venue guidance on first-aid rooms, AEDs, and when to seek medical care.",
            .bigSight,
            "briefcase-medical",
            "https://www.bigsight.jp/organizer/faq/",
            "first aid aed doctor medicine 救護室 医師 看護師 医薬品"
        ),
        resource(
            "c108-international",
            .international,
            "C108 international participant guide",
            "English admission, cosplay, hall, genre, and visitor information.",
            .comiket,
            "globe",
            "https://www.comiket.co.jp/info-a/TAFO/C108TAFO/index.html",
            "english overseas foreign international 英語 海外 参加"
        ),
        resource(
            "beginner-guide-zh-hans",
            .international,
            "Beginner guide in Simplified Chinese",
            "Official preparation, packing, and day-of guidance in Simplified Chinese.",
            .comiket,
            "globe",
            "https://harenohi.comiket.co.jp/index.php/beginnersguide/chinese/",
            "simplified chinese 中文 简体 初心者 guide 中国語"
        ),
    ]

    static let sections: [ComiketToolboxSection] = ComiketToolboxResource.Category.allCases
        .compactMap {
            category in
            let matchingResources = Self.resources.filter { $0.category == category }
            return matchingResources.isEmpty
                ? nil
                : ComiketToolboxSection(category: category, resources: matchingResources)
        }

    static func sections(matching query: String) -> [ComiketToolboxSection] {
        sections.compactMap { section in
            let matches = section.resources.filter { $0.matches(query) }
            return matches.isEmpty
                ? nil
                : ComiketToolboxSection(category: section.category, resources: matches)
        }
    }

    private static func resource(
        _ id: String,
        _ category: ComiketToolboxResource.Category,
        _ title: LocalizedStringResource,
        _ summary: LocalizedStringResource,
        _ authority: ComiketToolboxResource.Authority,
        _ icon: String,
        _ url: String,
        _ searchTerms: String
    ) -> ComiketToolboxResource {
        ComiketToolboxResource(
            id: id,
            category: category,
            title: title,
            summary: summary,
            authority: authority,
            icon: icon,
            url: makeURL(url),
            searchTerms: searchTerms
        )
    }

    private static func makeURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid toolbox URL: \(value)")
        }
        return url
    }
}

struct ComiketChecklistItem: Identifiable, Sendable {
    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let icon: String
}

enum ComiketChecklistCatalog {
    static let items: [ComiketChecklistItem] = [
        item(
            "admission", "Ticket or wristband", "Check the correct day and entry type.", "door-open"
        ),
        item(
            "identification", "Photo ID",
            "Bring the original ID required by your ticket or purchases.", "circle-user"),
        item(
            "phone-power", "Phone and power bank",
            "Charge both before leaving and save key information offline.", "radio-tower"),
        item(
            "water-salt", "Water and electrolytes",
            "Bring enough to drink before entering the East area.", "briefcase-medical"),
        item(
            "heat", "Heat protection", "Pack a hat, sunscreen, cooling items, and a towel.",
            "triangle-alert"),
        item(
            "medicine", "Regular medicine", "The venue first-aid rooms do not provide medicine.",
            "briefcase-medical"),
        item(
            "transit", "Charged transit IC card", "Top it up before reaching the crowded stations.",
            "navigation"),
        item(
            "cash", "Small cash and coins", "Exact payment keeps circle transactions quick.",
            "circle"),
        item(
            "offline-plan", "Offline circle list and maps",
            "Save your priorities in case mobile service is congested.", "map"),
        item(
            "bags", "Strong shopping bags", "Protect purchases without blocking crowded aisles.",
            "shopping-cart"),
        item(
            "weather", "Weather and rain gear", "Check the forecast again before departure.",
            "sparkles"),
    ]

    private static func item(
        _ id: String,
        _ title: LocalizedStringResource,
        _ detail: LocalizedStringResource,
        _ icon: String
    ) -> ComiketChecklistItem {
        ComiketChecklistItem(id: id, title: title, detail: detail, icon: icon)
    }
}

@MainActor
@Observable
final class ComiketChecklistStore {
    private static let completedKey = "comiket.toolbox.checklist.completed.v1"

    private let defaults: UserDefaults
    private(set) var completedIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let knownIDs = Set(ComiketChecklistCatalog.items.map(\.id))
        let storedIDs = Set(defaults.stringArray(forKey: Self.completedKey) ?? [])
        completedIDs = storedIDs.intersection(knownIDs)
    }

    var completedCount: Int { completedIDs.count }

    func isCompleted(_ item: ComiketChecklistItem) -> Bool {
        completedIDs.contains(item.id)
    }

    func setCompleted(_ completed: Bool, for item: ComiketChecklistItem) {
        if completed {
            completedIDs.insert(item.id)
        } else {
            completedIDs.remove(item.id)
        }
        persist()
    }

    func reset() {
        completedIDs.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(completedIDs.sorted(), forKey: Self.completedKey)
    }
}
