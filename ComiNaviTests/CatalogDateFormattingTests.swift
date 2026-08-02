import Foundation
import XCTest
@testable import ComiNavi

final class CatalogDateFormattingTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_US_POSIX")

    func testCurrentYearDateOmitsRedundantYear() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 23)
        let eventDate = try date(year: 2026, month: 8, day: 15)

        let formatted = eventDate.formatted(
            CatalogDateFormatting.full(
                for: eventDate,
                relativeTo: referenceDate,
                calendar: calendar
            ).locale(locale)
        )

        XCTAssertFalse(formatted.contains("2026"))
    }

    func testDifferentYearDateIncludesYear() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 23)
        let eventDate = try date(year: 2025, month: 12, day: 30)

        let formatted = eventDate.formatted(
            CatalogDateFormatting.abbreviated(
                for: eventDate,
                relativeTo: referenceDate,
                calendar: calendar
            ).locale(locale)
        )

        XCTAssertTrue(formatted.contains("2025"))
    }

    func testCurrentYearEventRangeOmitsRedundantYear() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 23)
        let startDate = try date(year: 2026, month: 8, day: 15)
        let endDate = try date(year: 2026, month: 8, day: 16)

        let formatted = CatalogDateFormatting.eventRange(
            from: startDate,
            through: endDate,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )

        XCTAssertFalse(formatted.contains("2026"))
        XCTAssertTrue(formatted.contains("15"))
        XCTAssertTrue(formatted.contains("16"))
    }

    func testPastEventRangeIncludesYearOnce() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 23)
        let startDate = try date(year: 2024, month: 8, day: 11)
        let endDate = try date(year: 2024, month: 8, day: 12)

        let formatted = CatalogDateFormatting.eventRange(
            from: startDate,
            through: endDate,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )

        XCTAssertTrue(formatted.contains("2024"))
        XCTAssertTrue(formatted.contains("11"))
        XCTAssertTrue(formatted.contains("12"))
    }

    private func date(year: Int, month: Int, day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
