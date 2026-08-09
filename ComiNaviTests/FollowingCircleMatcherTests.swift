import XCTest

@testable import ComiNavi

final class FollowingCircleMatcherTests: XCTestCase {
  func testMatchingUsesOnlyLocalCatalogXLinksAndKeepsABTogether() {
    let a = circle(id: 1, side: 0)
    let b = circle(id: 2, side: 1)
    let account = FollowingAccount(
      id: "x-42",
      userName: "one_year_war",
      name: "一年戦争",
      url: URL(string: "https://x.com/one_year_war")!,
      profilePicture: nil
    )
    let extensions = [
      extensionRecord(id: 1, publicID: 101),
      extensionRecord(id: 2, publicID: 102),
    ]

    let matches = FollowingCircleMatcher.match(
      accounts: [account],
      circles: [a, b],
      extensions: extensions
    )
    XCTAssertEqual(Set(matches.map(\.publicCircleID)), [101, 102])

    let importedAt = Date(timeIntervalSince1970: 100)
    let sources = matches.map {
      ImportedCircleSource(
        eventNumber: 108,
        publicCircleID: $0.publicCircleID,
        twitterUserID: account.id,
        twitterUserName: account.userName,
        twitterDisplayName: account.name,
        profilePictureURL: nil,
        firstImportedAt: importedAt,
        lastSeenAt: importedAt
      )
    }
    let resolved = FollowingCircleMatcher.resolveImportedCircles(
      sources: sources,
      circles: [b, a],
      extensions: extensions
    )

    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved[0].circles.map(\.id), [1, 2])
    XCTAssertEqual(resolved[0].sources.map(\.twitterUserID), ["x-42"])
  }

  func testUnknownFollowedAccountsDoNotBecomeCircleMatches() {
    let matches = FollowingCircleMatcher.match(
      accounts: [
        FollowingAccount(
          id: "x-9",
          userName: "someone_else",
          name: "Someone Else",
          url: URL(string: "https://x.com/someone_else")!,
          profilePicture: nil
        )
      ],
      circles: [circle(id: 1, side: 0)],
      extensions: [extensionRecord(id: 1, publicID: 101)]
    )

    XCTAssertTrue(matches.isEmpty)
  }

  func testMatchingKeepsEveryFollowedAccountLinkedToTheSameCircle() {
    let accounts = [
      FollowingAccount(
        id: "x-1",
        userName: "one_year_war",
        name: "一年戦争",
        url: URL(string: "https://x.com/one_year_war")!,
        profilePicture: nil
      ),
      FollowingAccount(
        id: "x-2",
        userName: "takeda_staff",
        name: "武田スタッフ",
        url: URL(string: "https://x.com/takeda_staff")!,
        profilePicture: nil
      ),
    ]
    var catalogCircle = circle(id: 1, side: 0)
    catalogCircle.url = "https://twitter.com/takeda_staff"

    let matches = FollowingCircleMatcher.match(
      accounts: accounts,
      circles: [catalogCircle],
      extensions: [extensionRecord(id: 1, publicID: 101)]
    )

    XCTAssertEqual(Set(matches.map(\.publicCircleID)), [101])
    XCTAssertEqual(Set(matches.map(\.account.id)), ["x-1", "x-2"])
  }

  private func circle(id: Int, side: Int) -> CirclemsDataSchema.ComiketCircleWC {
    CirclemsDataSchema.ComiketCircleWC(
      comiketNo: 108,
      id: id,
      pageNo: 1,
      cutIndex: id,
      day: 1,
      blockId: 1,
      spaceNo: 1,
      spaceNoSub: side,
      genreId: 1,
      circleName: "一年戦争",
      circleKana: nil,
      penName: "武田",
      bookName: nil,
      url: nil,
      mailAddr: nil,
      description: nil,
      memo: nil,
      updateId: 100 + id,
      updateData: nil,
      circlems: nil,
      rss: nil,
      updateFlag: nil
    )
  }

  private func extensionRecord(
    id: Int,
    publicID: Int
  ) -> CirclemsDataSchema.ComiketCircleExtend {
    CirclemsDataSchema.ComiketCircleExtend(
      comiketNo: 108,
      id: id,
      WCId: publicID,
      twitterURL: "https://twitter.com/one_year_war?t=tracking",
      pixivURL: nil,
      CirclemsPortalURL: nil
    )
  }
}
