@testable import ComiNavi
import Sentry
import XCTest

final class AppTrackTests: XCTestCase {
    func testUserIntentBreadcrumbUsesStableStructuredShape() {
        let breadcrumb = AppTrack.userIntentBreadcrumb(
            .favoriteAdded,
            data: [
                "event_number": 108,
                "circle_count": 2,
            ]
        )

        XCTAssertEqual(breadcrumb.type, "user")
        XCTAssertEqual(breadcrumb.level, .info)
        XCTAssertEqual(breadcrumb.category, "user.favorite")
        XCTAssertEqual(breadcrumb.message, "favorite.add")
        XCTAssertEqual(breadcrumb.data?["event_number"] as? Int, 108)
        XCTAssertEqual(breadcrumb.data?["circle_count"] as? Int, 2)
    }

    func testUserIntentCategoriesSeparateIntentSurfaces() {
        XCTAssertEqual(
            AppTrack.userIntentBreadcrumb(.authenticationStarted).category,
            "user.authentication"
        )
        XCTAssertEqual(
            AppTrack.userIntentBreadcrumb(.profileUpdated).category,
            "user.profile"
        )
        XCTAssertEqual(
            AppTrack.userIntentBreadcrumb(.eventReminderChanged).category,
            "user.reminder"
        )
        XCTAssertEqual(
            AppTrack.userIntentBreadcrumb(.followingImportStarted).category,
            "user.following_import"
        )
        XCTAssertEqual(
            AppTrack.userIntentBreadcrumb(.sharedPlanMemoUpdated).category,
            "user.shared_plan"
        )
    }

    func testEveryIntentProducesStableNonemptyBreadcrumbFields() {
        for intent in AppTrack.UserIntent.allCases {
            let breadcrumb = AppTrack.userIntentBreadcrumb(intent)

            XCTAssertFalse(breadcrumb.category.isEmpty, intent.rawValue)
            XCTAssertEqual(breadcrumb.message, intent.rawValue)
        }
    }

    func testEmptyIntentDataIsNotAttached() {
        XCTAssertNil(AppTrack.userIntentBreadcrumb(.sharedPlanArchived).data)
    }

    func testUserIntentPostHogEventUsesStableNameAndSafeContext() {
        let event = AppTrack.userIntentPostHogEvent(
            .sharedPlanMemoUpdated,
            data: [
                "plan_id": "plan-1",
                "wc_id": 42,
            ]
        )

        XCTAssertEqual(event.name, "shared_plan.memo_update")
        XCTAssertEqual(event.properties["intent_category"] as? String, "user.shared_plan")
        XCTAssertEqual(event.properties["plan_id"] as? String, "plan-1")
        XCTAssertEqual(event.properties["wc_id"] as? Int, 42)
    }

    func testEveryIntentProducesStablePostHogEventNameAndCategory() {
        for intent in AppTrack.UserIntent.allCases {
            let event = AppTrack.userIntentPostHogEvent(intent)

            XCTAssertEqual(event.name, intent.rawValue)
            XCTAssertEqual(event.properties["intent_category"] as? String, intent.category)
        }
    }
}
