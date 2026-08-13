@testable import ComiNavi
import UIKit
import XCTest

@MainActor
final class IssueReportTests: XCTestCase {
    func testSubmitTrimsMessageAndOmitsBlankContactEmail() {
        let reporter = RecordingIssueReportReporter()
        let context = fixtureContext(publicUserID: "user-public-42")
        let model = IssueReportModel(context: context, reporter: reporter)
        model.message = "  Favorite colors disappeared after import.\n"
        model.contactEmail = "   "

        model.submit()

        XCTAssertEqual(model.referenceID, "event-reference-123")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(reporter.submissions, [
            IssueReportSubmission(
                message: "Favorite colors disappeared after import.",
                contactEmail: nil,
                context: context,
                screenshotPNGData: nil
            ),
        ])
    }

    func testSubmitPreservesDiagnosticsAndContactEmail() {
        let reporter = RecordingIssueReportReporter()
        let context = fixtureContext(publicUserID: nil)
        let model = IssueReportModel(context: context, reporter: reporter)
        model.message = "The marker is missing"
        model.contactEmail = " user@example.com "

        model.submit()

        XCTAssertEqual(reporter.submissions.first?.contactEmail, "user@example.com")
        XCTAssertEqual(reporter.submissions.first?.context.installationID, "installation-123")
        XCTAssertEqual(reporter.submissions.first?.context.comiketNumber, 108)
    }

    func testBlankMessageDoesNotSubmit() {
        let reporter = RecordingIssueReportReporter()
        let model = IssueReportModel(
            context: fixtureContext(publicUserID: "user-public-42"),
            reporter: reporter
        )
        model.message = " \n "

        model.submit()

        XCTAssertTrue(reporter.submissions.isEmpty)
        XCTAssertNil(model.referenceID)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSubmitIncludesOnlyExplicitlyAttachedScreenshot() {
        let reporter = RecordingIssueReportReporter()
        let context = fixtureContext(publicUserID: "user-public-42")
        let model = IssueReportModel(context: context, reporter: reporter)
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47])
        model.message = "The marker is missing"
        model.attachPreparedScreenshot(screenshot)

        model.submit()

        XCTAssertEqual(reporter.submissions.first?.screenshotPNGData, screenshot)

        model.removeScreenshot()
        XCTAssertNil(model.screenshotPNGData)
    }

    func testScreenshotProcessorNormalizesSelectedImageToPNG() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 96))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 96))
        }
        let jpegData = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))

        let pngData = try await IssueReportScreenshotProcessor.makePNGData(from: jpegData)

        XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertLessThanOrEqual(
            pngData.count,
            IssueReportScreenshotProcessor.maximumAttachmentSize
        )
    }

    private func fixtureContext(publicUserID: String?) -> IssueReportContext {
        IssueReportContext(
            publicUserID: publicUserID,
            displayName: publicUserID == nil ? nil : "Sakana",
            installationID: "installation-123",
            appVersion: "1.2.3 (45)",
            deviceModel: "iPhone",
            operatingSystem: "iOS 26.5",
            buildEnvironment: "testflight",
            catalogMode: "cominavi",
            comiketNumber: 108
        )
    }
}

@MainActor
private final class RecordingIssueReportReporter: IssueReportSubmitting {
    private(set) var submissions: [IssueReportSubmission] = []

    func submit(_ submission: IssueReportSubmission) throws -> String {
        submissions.append(submission)
        return "event-reference-123"
    }
}
