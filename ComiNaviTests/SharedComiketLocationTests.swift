import Foundation
import XCTest

@testable import ComiNavi

@MainActor
final class SharedComiketLocationTests: XCTestCase {
  func testLinkRoundTripUsesStableCatalogIdentifiersAndSide() throws {
    let location = try XCTUnwrap(
      SharedComiketLocation(
        eventNumber: 108,
        sceneID: .init(day: 2, mapID: 4),
        tableID: .init(blockID: 37, spaceNumber: 16),
        subspace: 1
      ))

    XCTAssertEqual(
      location.url.absoluteString,
      "cominavi://p/AWwCBCUQAg"
    )
    XCTAssertLessThan(location.url.absoluteString.count, 30)
    XCTAssertEqual(SharedComiketLocation(url: location.url), location)
    XCTAssertEqual(
      location.clipboardText(locationText: "2日目 西ホール ま16b付近"),
      "2日目 西ホール ま16b付近\ncominavi://p/AWwCBCUQAg"
    )
  }

  func testLinkWithoutSideDoesNotInventOne() throws {
    let url = try XCTUnwrap(
      URL(
        string: "cominavi://place?v=1&event=108&day=1&map=2&block_id=10&space=7"
      ))

    XCTAssertNil(try XCTUnwrap(SharedComiketLocation(url: url)).subspace)
  }

  func testLegacyQueryLinkRemainsReadable() throws {
    let url = try XCTUnwrap(
      URL(
        string: "cominavi://place?v=1&event=108&day=1&map=2&block_id=10&space=7"
      ))

    let location = try XCTUnwrap(SharedComiketLocation(url: url))
    XCTAssertNil(location.subspace)
    XCTAssertEqual(location.url.absoluteString, "cominavi://p/AWwBAgoHAA")
  }

  func testParserRejectsDuplicateFieldsUnknownVersionAndInvalidRanges() {
    XCTAssertNil(
      parse(
        "cominavi://place?v=1&event=108&day=1&day=2&map=2&block_id=10&space=7"
      ))
    XCTAssertNil(
      parse(
        "cominavi://place?v=2&event=108&day=1&map=2&block_id=10&space=7"
      ))
    XCTAssertNil(
      parse(
        "cominavi://place?v=1&event=108&day=0&map=2&block_id=10&space=7"
      ))
    XCTAssertNil(
      parse(
        "cominavi://place?v=1&event=108&day=1&map=2&block_id=10&space=7&side=c"
      ))
  }

  func testOAuthCallbackIsNotTreatedAsALocationLink() throws {
    let oauthURL = try XCTUnwrap(URL(string: "cominavi://oauth/circlems/landing?code=secret"))

    XCTAssertFalse(SharedComiketLocation.isLocationURL(oauthURL))
    XCTAssertNil(SharedComiketLocation(url: oauthURL))
  }

  func testClipboardTextFindsAnEmbeddedLink() throws {
    let text =
      "2日目 西ホール ま16a\n<cominavi://place?v=1&event=108&day=2&map=4&block_id=37&space=16&side=a>"

    let location = try XCTUnwrap(SharedComiketLocation.first(in: text))

    XCTAssertEqual(location.eventNumber, 108)
    XCTAssertEqual(location.sceneID, .init(day: 2, mapID: 4))
    XCTAssertEqual(location.tableID, .init(blockID: 37, spaceNumber: 16))
    XCTAssertEqual(location.subspace, 0)
  }

  func testInboxAcknowledgesOnlyTheCurrentRequest() throws {
    let inbox = SharedLocationInbox()
    let url = try XCTUnwrap(
      URL(
        string: "cominavi://place?v=1&event=108&day=2&map=4&block_id=37&space=16"
      ))

    XCTAssertTrue(inbox.receive(url: url))
    let request = try XCTUnwrap(inbox.pending)
    inbox.acknowledge(UUID())
    XCTAssertEqual(inbox.pending, request)
    inbox.acknowledge(request.id)
    XCTAssertNil(inbox.pending)
  }

  func testAutomaticClipboardImporterReadsEachChangeOnlyOnceAndIgnoresOtherText() throws {
    let suiteName = "SharedComiketLocationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let pasteboard = TestPasteboard(
      changeCount: 9,
      string: "cominavi://place?v=1&event=108&day=2&map=4&block_id=37&space=16"
    )
    let importer = SharedLocationClipboardImporter(
      pasteboard: pasteboard,
      defaults: defaults
    )
    let inbox = SharedLocationInbox()

    XCTAssertTrue(importer.importIfChanged(into: inbox))
    let request = try XCTUnwrap(inbox.pending)
    inbox.acknowledge(request.id)
    XCTAssertFalse(importer.importIfChanged(into: inbox))
    XCTAssertEqual(pasteboard.stringReadCount, 1)

    pasteboard.changeCount = 10
    pasteboard.string = "ordinary clipboard text"
    XCTAssertFalse(importer.importIfChanged(into: inbox))
    XCTAssertNil(inbox.pending)
    XCTAssertNil(inbox.issue)
    XCTAssertEqual(pasteboard.stringReadCount, 2)
  }

  private func parse(_ value: String) -> SharedComiketLocation? {
    URL(string: value).flatMap(SharedComiketLocation.init(url:))
  }
}

@MainActor
private final class TestPasteboard: SharedLocationPasteboard {
  var changeCount: Int
  var hasStrings: Bool { storedString != nil }
  var string: String? {
    get {
      stringReadCount += 1
      return storedString
    }
    set {
      storedString = newValue
    }
  }
  private(set) var stringReadCount = 0
  private var storedString: String?

  init(changeCount: Int, string: String?) {
    self.changeCount = changeCount
    storedString = string
  }
}
