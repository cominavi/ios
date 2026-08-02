import Foundation
import XCTest
@testable import ComiNavi

final class CatalogEventTests: XCTestCase {
    func testEventListDecodesDocumentedCirclemsKeys() throws {
        let response = try decodeEventList(
            """
            {
              "status": "success",
              "response": {
                "list": [
                  { "EventId": 190, "EventNo": 104 },
                  { "EventId": 230, "EventNo": 108 }
                ],
                "LatestEventId": 230,
                "LatestEventNo": 108
              }
            }
            """
        )

        XCTAssertEqual(response.status, "success")
        XCTAssertEqual(response.response.latestEventID, 230)
        XCTAssertEqual(response.response.latestEventNumber, 108)
        XCTAssertEqual(response.response.list.map(\.eventID), [190, 230])
        XCTAssertEqual(response.response.list.map(\.eventNumber), [104, 108])
    }

    func testAvailableEventsRespectBothLatestBoundariesAndSortNewestFirst() throws {
        let response = try decodeEventList(
            """
            {
              "status": "success",
              "response": {
                "list": [
                  { "EventId": 180, "EventNo": 100 },
                  { "EventId": 230, "EventNo": 108 },
                  { "EventId": 230, "EventNo": 108 },
                  { "EventId": 220, "EventNo": 109 },
                  { "EventId": 240, "EventNo": 109 }
                ],
                "LatestEventId": 230,
                "LatestEventNo": 108
              }
            }
            """
        )

        XCTAssertEqual(
            CatalogEvent.available(from: response.response),
            [
                CatalogEvent(id: 230, number: 108),
                CatalogEvent(id: 180, number: 100),
            ]
        )
    }

    func testPreferredEventRestoresSupportedSelection() {
        let events = [
            CatalogEvent(id: 230, number: 108),
            CatalogEvent(id: 190, number: 104),
        ]

        XCTAssertEqual(
            CatalogEvent.preferred(in: events, persistedEventID: 190),
            CatalogEvent(id: 190, number: 104)
        )
    }

    func testPreferredEventFallsBackToNewestWhenStoredEventIsUnavailable() {
        let events = [
            CatalogEvent(id: 230, number: 108),
            CatalogEvent(id: 190, number: 104),
        ]

        XCTAssertEqual(
            CatalogEvent.preferred(in: events, persistedEventID: 999),
            CatalogEvent(id: 230, number: 108)
        )
        XCTAssertNil(CatalogEvent.preferred(in: [], persistedEventID: 230))
    }

    func testKnownEventExposesItsScheduledDateRange() throws {
        let event = CatalogEvent(id: 230, number: 108)
        let dates = try XCTUnwrap(event.scheduledDateRange?.dates(in: Calendar(identifier: .gregorian)))
        let calendar = Calendar(identifier: .gregorian)

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: dates.start), DateComponents(year: 2026, month: 8, day: 15))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: dates.end), DateComponents(year: 2026, month: 8, day: 16))
    }

    func testUnknownEventHasNoScheduledDateRange() {
        XCTAssertNil(CatalogEvent(id: 999, number: 999).scheduledDateRange)
    }

    private func decodeEventList(_ json: String) throws -> CirclemsAPI.EventListResponse {
        try JSONDecoder().decode(
            CirclemsAPI.EventListResponse.self,
            from: Data(json.utf8)
        )
    }
}
