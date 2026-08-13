import Foundation
import XCTest

@testable import ComiNavi

@MainActor
final class ComiketToolboxTests: XCTestCase {
    func testCatalogUsesUniqueSecureOfficialResources() {
        let resources = ComiketToolboxCatalog.resources

        XCTAssertGreaterThanOrEqual(resources.count, 25)
        XCTAssertEqual(Set(resources.map(\.id)).count, resources.count)
        XCTAssertEqual(Set(resources.map(\.url)).count, resources.count)
        XCTAssertTrue(resources.allSatisfy { $0.url.scheme == "https" })
        XCTAssertTrue(resources.allSatisfy { $0.url.host() != nil })

        let ids = Set(resources.map(\.id))
        XCTAssertTrue(ids.contains("comiket-x"))
        XCTAssertTrue(ids.contains("c108-last-minute-roundup"))
        XCTAssertTrue(ids.contains("c108-entry"))
        XCTAssertTrue(ids.contains("c108-notes"))
        XCTAssertTrue(ids.contains("c108-food"))
        XCTAssertTrue(ids.contains("comiket-heatstroke"))
        XCTAssertTrue(ids.contains("lost-and-found"))
        XCTAssertTrue(ids.contains("big-sight-accessibility"))
        XCTAssertTrue(ids.contains("jma-tokyo-weather"))
        XCTAssertTrue(ids.contains("haneda-airport-limousine-c108"))

        XCTAssertEqual(
            resources.first { $0.id == "c108-last-minute-roundup" }?.url.absoluteString,
            "https://posfie.com/@comiketofficial/p/KaBB6nx"
        )
        XCTAssertEqual(
            resources.first { $0.id == "haneda-airport-limousine-c108" }?.url.absoluteString,
            "https://x.com/comiketofficial/status/2087798510016208907"
        )

        let simplifiedChineseGuide = resources.first { $0.id == "beginner-guide-zh-hans" }
        XCTAssertEqual(
            simplifiedChineseGuide?.url.absoluteString,
            "https://harenohi.comiket.co.jp/index.php/beginnersguide/beginnersguide-sc/"
        )
    }

    func testCurrentNoticesIncludeFreshOfficialWarnings() {
        let noticeIDs = Set(C108ToolboxNoticeCatalog.notices.map(\.id))

        XCTAssertTrue(noticeIDs.contains("station-crowding"))
        XCTAssertTrue(noticeIDs.contains("east-galleria"))
        XCTAssertTrue(noticeIDs.contains("closed-halls"))
        XCTAssertTrue(noticeIDs.contains("east-drinks"))
        XCTAssertTrue(noticeIDs.contains("admission"))
    }

    func testEveryCategoryIsRepresentedAndFilteringKeepsItsSection() throws {
        XCTAssertEqual(
            Set(ComiketToolboxCatalog.sections.map(\.category)),
            Set(ComiketToolboxResource.Category.allCases)
        )

        let heatResults = ComiketToolboxCatalog.sections(matching: "熱中症")
            .flatMap(\.resources)
        XCTAssertTrue(heatResults.contains { $0.id == "comiket-heatstroke" })

        let twitterResults = ComiketToolboxCatalog.sections(matching: "twitter")
            .flatMap(\.resources)
        XCTAssertTrue(twitterResults.contains { $0.id == "comiket-x" })

        let noResults = ComiketToolboxCatalog.sections(matching: "not-a-real-toolbox-topic")
        XCTAssertTrue(noResults.isEmpty)
    }

    func testChecklistPersistsKnownItemsAndDropsRetiredOnes() throws {
        let suiteName = "ComiketToolboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["retired-item"], forKey: "comiket.toolbox.checklist.completed.v1")
        let firstStore = ComiketChecklistStore(defaults: defaults)
        XCTAssertEqual(firstStore.completedCount, 0)

        let item = try XCTUnwrap(ComiketChecklistCatalog.items.first)
        firstStore.setCompleted(true, for: item)
        XCTAssertTrue(firstStore.isCompleted(item))

        let reopenedStore = ComiketChecklistStore(defaults: defaults)
        XCTAssertTrue(reopenedStore.isCompleted(item))
        XCTAssertEqual(reopenedStore.completedCount, 1)

        reopenedStore.reset()
        XCTAssertEqual(ComiketChecklistStore(defaults: defaults).completedCount, 0)
    }
}
