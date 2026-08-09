import Foundation

struct CircleExternalLink: Identifiable, Equatable, Sendable {
    enum Kind: Int, Equatable, Sendable {
        case xProfile
        case pixiv
        case website
        case circlems

        var title: LocalizedStringResource {
            switch self {
            case .xProfile: "X profile"
            case .pixiv: "Pixiv"
            case .website: "Website"
            case .circlems: "Circle.ms"
            }
        }

        var systemImage: String {
            switch self {
            case .xProfile: "at"
            case .pixiv: "paintbrush.pointed"
            case .website: "globe"
            case .circlems: "person.2.crop.square.stack"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .xProfile: "circle-link-x"
            case .pixiv: "circle-link-pixiv"
            case .website: "circle-link-website"
            case .circlems: "circle-link-circlems"
            }
        }
    }

    struct RawValue: Sendable {
        let value: String?
        let hint: Kind?

        init(_ value: String?, hint: Kind? = nil) {
            self.value = value
            self.hint = hint
        }
    }

    let kind: Kind
    let url: URL

    var id: String { url.absoluteString }
    var title: LocalizedStringResource { kind.title }
    var systemImage: String { kind.systemImage }
    var accessibilityIdentifier: String { kind.accessibilityIdentifier }

    var preview: String {
        switch kind {
        case .xProfile:
            guard let handle = url.pathComponents.dropFirst().first else {
                return url.host ?? url.absoluteString
            }
            return "@\(handle)"
        case .pixiv:
            let components = url.pathComponents.filter { $0 != "/" }
            if let usersIndex = components.firstIndex(of: "users"),
               components.indices.contains(usersIndex + 1) {
                return String(localized: "Pixiv ID \(components[usersIndex + 1])")
            }
            return url.host ?? url.absoluteString
        case .circlems:
            if let circleID = url.pathComponents.reversed().first(where: {
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            }) {
                return String(localized: "Circle ID \(circleID)")
            }
            return url.host ?? url.absoluteString
        case .website:
            return url.host ?? url.absoluteString
        }
    }
}

enum CircleExternalLinkNormalizer {
    static func links(
        circle: CirclemsDataSchema.ComiketCircleWC,
        extensionRecord: CirclemsDataSchema.ComiketCircleExtend?,
        enrichmentProfileURL: URL?
    ) -> [CircleExternalLink] {
        links(from: [
            .init(extensionRecord?.twitterURL, hint: .xProfile),
            .init(enrichmentProfileURL?.absoluteString, hint: .xProfile),
            .init(extensionRecord?.pixivURL, hint: .pixiv),
            .init(circle.url),
            .init(circle.rss),
            .init(circle.circlems, hint: .circlems),
            .init(extensionRecord?.CirclemsPortalURL, hint: .circlems)
        ])
    }

    static func links(from rawValues: [CircleExternalLink.RawValue]) -> [CircleExternalLink] {
        var candidates: [(link: CircleExternalLink, order: Int)] = []

        for (order, rawValue) in rawValues.enumerated() {
            guard let value = rawValue.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }

            if shouldExtractXHandle(from: value, hint: rawValue.hint),
               let handle = firstXHandle(in: value) {
                candidates.append((xLink(handle: handle), order))
            }

            for detectedURL in detectedWebURLs(in: value) {
                guard let link = normalizedLink(detectedURL, hint: rawValue.hint) else {
                    continue
                }
                candidates.append((link, order))
            }

            if rawValue.hint == .xProfile,
               candidatesForOrder(order, in: candidates).isEmpty,
               let handle = normalizedXHandle(value) {
                candidates.append((xLink(handle: handle), order))
            }
        }

        var seen: Set<String> = []
        var hasCirclemsLink = false
        return candidates
            .sorted {
                if $0.link.kind.rawValue != $1.link.kind.rawValue {
                    return $0.link.kind.rawValue < $1.link.kind.rawValue
                }
                return $0.order < $1.order
            }
            .compactMap { candidate in
                if candidate.link.kind == .circlems {
                    guard !hasCirclemsLink else { return nil }
                    hasCirclemsLink = true
                }
                let deduplicationKey = candidate.link.kind == .xProfile
                    ? candidate.link.id.lowercased()
                    : candidate.link.id
                return seen.insert(deduplicationKey).inserted ? candidate.link : nil
            }
    }

    private static func candidatesForOrder(
        _ order: Int,
        in candidates: [(link: CircleExternalLink, order: Int)]
    ) -> [CircleExternalLink] {
        candidates.lazy.filter { $0.order == order }.map(\.link)
    }

    private static func detectedWebURLs(in value: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return detector.matches(in: value, range: range).compactMap { result in
            guard result.resultType == .link,
                  let url = result.url,
                  ["http", "https"].contains(url.scheme?.lowercased())
            else { return nil }
            return url
        }
    }

    private static func normalizedLink(
        _ url: URL,
        hint: CircleExternalLink.Kind?
    ) -> CircleExternalLink? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host.contains("."),
              !looksLikeEmailURL(components)
        else { return nil }

        if isXHost(host) {
            return normalizeXURL(components)
        }
        if isPixivHost(host) || hint == .pixiv {
            return normalizePixivURL(components)
        }

        components.fragment = nil
        components.queryItems = cleanedQueryItems(components.queryItems)
        if isCirclemsHost(host) || hint == .circlems {
            components.scheme = "https"
            guard let normalizedURL = components.url else { return nil }
            return CircleExternalLink(kind: .circlems, url: normalizedURL)
        }

        guard let normalizedURL = components.url else { return nil }
        return CircleExternalLink(kind: .website, url: normalizedURL)
    }

    private static func normalizeXURL(_ original: URLComponents) -> CircleExternalLink? {
        var components = original
        var pathComponents = components.path
            .split(separator: "/")
            .map(String.init)
        if let first = pathComponents.first {
            pathComponents[0] = first.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        }
        guard let handle = pathComponents.first.flatMap(normalizedXHandle) else {
            return nil
        }
        pathComponents[0] = handle
        components.scheme = "https"
        components.host = "x.com"
        components.port = nil
        components.path = "/" + pathComponents.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return CircleExternalLink(kind: .xProfile, url: url)
    }

    private static func normalizePixivURL(_ original: URLComponents) -> CircleExternalLink? {
        var components = original
        let host = components.host?.lowercased() ?? ""
        guard isPixivHost(host) else { return nil }

        var convertedLegacyProfile = false
        if components.path.lowercased() == "/member.php",
           let userID = components.queryItems?.first(where: {
               $0.name.caseInsensitiveCompare("id") == .orderedSame
           })?.value,
           userID.allSatisfy(\.isNumber),
           !userID.isEmpty {
            components.path = "/users/\(userID)"
            convertedLegacyProfile = true
        }
        components.scheme = "https"
        components.host = host == "pixiv.net" || host == "www.pixiv.net"
            ? "www.pixiv.net"
            : host
        components.port = nil
        components.queryItems = convertedLegacyProfile
            ? nil
            : cleanedQueryItems(components.queryItems)
        components.fragment = nil
        guard let url = components.url else { return nil }
        return CircleExternalLink(kind: .pixiv, url: url)
    }

    private static func cleanedQueryItems(_ items: [URLQueryItem]?) -> [URLQueryItem]? {
        let trackingNames: Set<String> = [
            "_r", "_t", "fbclid", "gclid", "igshid", "ref", "ref_src", "s", "t"
        ]
        let cleaned = items?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingNames.contains(name)
        }
        return cleaned?.isEmpty == true ? nil : cleaned
    }

    private static func shouldExtractXHandle(
        from value: String,
        hint: CircleExternalLink.Kind?
    ) -> Bool {
        if hint == .xProfile { return true }
        let folded = value.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.contains("twitter")
            || folded.contains("x.com")
            || folded.range(of: #"^https?://\s*@"#, options: .regularExpression) != nil
            || folded.range(of: #"^https?://\s*x\s*(?:\(twitter\))?\s*:?[\s@]"#, options: .regularExpression) != nil
            || folded.contains("(x)")
    }

    private static func firstXHandle(in value: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"@([A-Za-z0-9_]{1,15})(?=$|[^A-Za-z0-9_])"#
        ) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let handleRange = Range(match.range(at: 1), in: value)
        else { return nil }
        return normalizedXHandle(String(value[handleRange]))
    }

    private static func normalizedXHandle(_ value: String) -> String? {
        let handle = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
        let reserved: Set<String> = [
            "about", "compose", "explore", "hashtag", "home", "i", "intent",
            "messages", "search", "settings", "share"
        ]
        guard (1...15).contains(handle.count),
              handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              !reserved.contains(handle.lowercased())
        else { return nil }
        return handle
    }

    private static func xLink(handle: String) -> CircleExternalLink {
        CircleExternalLink(
            kind: .xProfile,
            url: URL(string: "https://x.com/\(handle)")!
        )
    }

    private static func looksLikeEmailURL(_ components: URLComponents) -> Bool {
        guard components.host != nil else { return true }
        let value = (components.string ?? "")
            .removingPercentEncoding ?? components.string ?? ""
        return value.range(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isXHost(_ host: String) -> Bool {
        host == "x.com"
            || host == "www.x.com"
            || host == "twitter.com"
            || host == "www.twitter.com"
            || host == "mobile.twitter.com"
    }

    private static func isPixivHost(_ host: String) -> Bool {
        host == "pixiv.net"
            || host == "www.pixiv.net"
            || host == "pixiv.me"
            || host == "www.pixiv.me"
    }

    private static func isCirclemsHost(_ host: String) -> Bool {
        host == "circle.ms" || host.hasSuffix(".circle.ms")
    }
}
