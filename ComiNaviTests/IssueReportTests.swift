@testable import ComiNavi
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
                context: context
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
