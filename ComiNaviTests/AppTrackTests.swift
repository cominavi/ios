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

    func testFollowingImportFailureEventHasActionableNonPIIDiagnostics() {
        let context = DecodingError.Context(
            codingPath: [FixtureCodingKey(stringValue: "importedAt")],
            debugDescription: "Expected an RFC 3339 timestamp."
        )
        let event = AppDiagnostics.followingImportFailureEvent(
            DecodingError.dataCorrupted(context),
            stage: "completion_decode",
            eventName: "done",
            dataByteCount: 481
        )

        XCTAssertEqual(event.logger, "following_import")
        XCTAssertEqual(event.transaction, "FollowingImport.importXFollowings")
        XCTAssertEqual(event.tags?["feature"], "x_following_import")
        XCTAssertEqual(event.tags?["failure_stage"], "completion_decode")
        XCTAssertEqual(event.tags?["stream_event"], "done")
        XCTAssertEqual(event.tags?["error_kind"], "data_corrupted")
        XCTAssertEqual(event.fingerprint, [
            "x-following-import-invalid-response",
            "completion_decode",
            "data_corrupted",
        ])
        XCTAssertEqual(event.extra?["coding_path"] as? String, "importedAt")
        XCTAssertEqual(event.extra?["data_byte_count"] as? Int, 481)
        XCTAssertNil(event.extra?["twitter_user_name"])
        XCTAssertNil(event.extra?["response_body"])
    }

    private struct FixtureCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
