import Foundation

struct FollowingCircleMatch: Sendable {
  let publicCircleID: Int
  let circle: CirclemsDataSchema.ComiketCircleWC
  let account: FollowingAccount
}

struct FollowingImportedCircle: Identifiable, Sendable {
  let circles: [CirclemsDataSchema.ComiketCircleWC]
  let publicCircleIDsByCatalogID: [Int: Int]
  let sources: [ImportedCircleSource]
  var hallName: String? = nil

  var id: Int { publicCircleIDsByCatalogID.values.min() ?? circles[0].id }
  var circle: CirclemsDataSchema.ComiketCircleWC { circles[0] }
  var isCombinedAB: Bool { circles.count == 2 }
}

enum FollowingCircleMatcher {
  static func match(
    accounts: [FollowingAccount],
    circles: [CirclemsDataSchema.ComiketCircleWC],
    extensions: [CirclemsDataSchema.ComiketCircleExtend]
  ) -> [FollowingCircleMatch] {
    let accountsByHandle = Dictionary(
      grouping: accounts,
      by: { $0.userName.lowercased() }
    )
    let extensionByCircleID = Dictionary(
      extensions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var matchedSources: Set<String> = []

    return circles.flatMap { circle -> [FollowingCircleMatch] in
      guard let extensionRecord = extensionByCircleID[circle.id] else { return [] }
      return xHandles(circle: circle, extensionRecord: extensionRecord)
        .flatMap { accountsByHandle[$0] ?? [] }
        .filter { account in
          matchedSources.insert("\(extensionRecord.WCId):\(account.id)").inserted
        }
        .map { account in
          FollowingCircleMatch(
            publicCircleID: extensionRecord.WCId,
            circle: circle,
            account: account
          )
        }
    }
  }

  static func resolveImportedCircles(
    sources: [ImportedCircleSource],
    circles: [CirclemsDataSchema.ComiketCircleWC],
    extensions: [CirclemsDataSchema.ComiketCircleExtend]
  ) -> [FollowingImportedCircle] {
    let sourcesByPublicID = Dictionary(grouping: sources, by: \.publicCircleID)
    let extensionByCircleID = Dictionary(
      extensions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let importedCircles = circles.filter { circle in
      extensionByCircleID[circle.id].map { sourcesByPublicID[$0.WCId] != nil } ?? false
    }
    let groups = CatalogCirclePairing.groups(
      circles: importedCircles,
      extensionsByCircleID: extensionByCircleID
    )

    return groups.compactMap { members in
      var publicIDsByCatalogID: [Int: Int] = [:]
      var groupSourcesByTwitterUserID: [String: ImportedCircleSource] = [:]
      for member in members {
        guard let publicID = extensionByCircleID[member.id]?.WCId else { continue }
        publicIDsByCatalogID[member.id] = publicID
        for source in sourcesByPublicID[publicID] ?? [] {
          groupSourcesByTwitterUserID[source.twitterUserID] = source
        }
      }
      guard !publicIDsByCatalogID.isEmpty else { return nil }
      return FollowingImportedCircle(
        circles: members,
        publicCircleIDsByCatalogID: publicIDsByCatalogID,
        sources: groupSourcesByTwitterUserID.values.sorted {
          ($0.twitterDisplayName.lowercased(), $0.twitterUserID)
            < ($1.twitterDisplayName.lowercased(), $1.twitterUserID)
        }
      )
    }
  }

  private static func xHandles(
    circle: CirclemsDataSchema.ComiketCircleWC,
    extensionRecord: CirclemsDataSchema.ComiketCircleExtend
  ) -> [String] {
    CircleExternalLinkNormalizer.links(
      circle: circle,
      extensionRecord: extensionRecord,
      enrichmentProfileURL: nil
    )
    .filter { $0.kind == .xProfile }
    .compactMap { $0.url.pathComponents.dropFirst().first?.lowercased() }
  }
}
