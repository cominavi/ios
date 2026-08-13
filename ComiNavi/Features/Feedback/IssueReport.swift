import Foundation
import ImageIO
import Observation
import PhotosUI
import Sentry
import SwiftUI
import UIKit

struct IssueReportContext: Equatable, Sendable {
    let publicUserID: String?
    let displayName: String?
    let installationID: String
    let appVersion: String
    let deviceModel: String
    let operatingSystem: String
    let buildEnvironment: String
    let catalogMode: String
    let comiketNumber: Int?

    @MainActor
    static func current(
        bundle: Bundle = .main,
        device: UIDevice = .current
    ) -> IssueReportContext {
        let profile = AppData.profileStore.isIdentityVerified
            ? AppData.profileStore.profile
            : nil
        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        return IssueReportContext(
            publicUserID: profile?.id,
            displayName: profile?.displayName,
            installationID: CominaviServiceClient.diagnosticsInstallationID,
            appVersion: "\(shortVersion) (\(buildNumber))",
            deviceModel: device.model,
            operatingSystem: "\(device.systemName) \(device.systemVersion)",
            buildEnvironment: AppEnvironment.current.build.rawValue,
            catalogMode: AppData.catalogLibrary.mode.rawValue,
            comiketNumber: AppData.catalogLibrary.dataSource?.comiket.number
        )
    }
}

struct IssueReportSubmission: Equatable, Sendable {
    let message: String
    let contactEmail: String?
    let context: IssueReportContext
    let screenshotPNGData: Data?
}

@MainActor
protocol IssueReportSubmitting {
    func submit(_ submission: IssueReportSubmission) throws -> String
}

enum IssueReportError: LocalizedError {
    case emptyMessage
    case screenshotUnavailable
    case unavailable

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            String(localized: "Please describe the issue before sending.")
        case .screenshotUnavailable:
            String(localized: "The selected screenshot could not be attached. Please choose another screenshot.")
        case .unavailable:
            String(localized: "Issue reporting is unavailable right now.")
        }
    }
}

enum IssueReportScreenshotProcessor {
    static let maximumAttachmentSize = 18 * 1_024 * 1_024

    static func makePNGData(from selectedData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(selectedData as CFData, nil) else {
                    throw IssueReportError.screenshotUnavailable
                }

                for maximumPixelSize in [3_072, 2_560, 2_048, 1_536, 1_024] {
                    let options: [CFString: Any] = [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                        kCGImageSourceShouldCacheImmediately: true,
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        options as CFDictionary
                    ), let pngData = UIImage(cgImage: image).pngData()
                    else {
                        continue
                    }
                    if pngData.count <= maximumAttachmentSize {
                        return pngData
                    }
                }

                throw IssueReportError.screenshotUnavailable
            }
        }.value
    }
}

@MainActor
struct SentryIssueReporter: IssueReportSubmitting {
    func submit(_ submission: IssueReportSubmission) throws -> String {
        guard SentrySDK.isEnabled else {
            throw IssueReportError.unavailable
        }

        let context = submission.context
        var breadcrumbData: [String: Any] = [
            "installation_id": context.installationID,
            "catalog_mode": context.catalogMode,
            "screenshot_attached": submission.screenshotPNGData != nil,
        ]
        breadcrumbData["comiket_number"] = context.comiketNumber
        let breadcrumb = Breadcrumb(level: .info, category: "user.feedback")
        breadcrumb.type = "user"
        breadcrumb.message = "User submitted an in-app issue report"
        breadcrumb.data = breadcrumbData
        SentrySDK.addBreadcrumb(breadcrumb)

        let eventID = SentrySDK.capture(message: "User-submitted issue report") { scope in
            if let publicUserID = context.publicUserID {
                let user = Sentry.User(userId: publicUserID)
                user.name = context.displayName
                scope.setUser(user)
            } else {
                scope.setUser(nil)
            }

            scope.setTag(value: "in_app", key: "feedback.source")
            scope.setTag(
                value: submission.screenshotPNGData == nil ? "false" : "true",
                key: "feedback.screenshot_attached"
            )
            scope.setTag(value: context.installationID, key: "cominavi.installation_id")
            scope.setTag(value: context.buildEnvironment, key: "cominavi.build_environment")
            scope.setTag(value: context.catalogMode, key: "cominavi.catalog_mode")
            if let comiketNumber = context.comiketNumber {
                scope.setTag(value: String(comiketNumber), key: "cominavi.comiket_number")
            }

            var diagnosticContext: [String: Any] = [
                "installation_id": context.installationID,
                "app_version": context.appVersion,
                "device_model": context.deviceModel,
                "operating_system": context.operatingSystem,
                "build_environment": context.buildEnvironment,
                "catalog_mode": context.catalogMode,
            ]
            diagnosticContext["public_user_id"] = context.publicUserID
            diagnosticContext["comiket_number"] = context.comiketNumber
            scope.setContext(value: diagnosticContext, key: "cominavi")
        }

        guard !eventID.isEqual(SentryId.empty) else {
            throw IssueReportError.unavailable
        }

        SentrySDK.capture(
            feedback: SentryFeedback(
                message: submission.message,
                name: context.displayName,
                email: submission.contactEmail,
                source: .custom,
                associatedEventId: eventID,
                attachments: submission.screenshotPNGData.map { [$0] }
            )
        )
        return eventID.sentryIdString
    }
}

@MainActor
@Observable
final class IssueReportModel {
    static let maximumMessageLength = 8_000

    var message = ""
    var contactEmail = ""
    private(set) var referenceID: String?
    private(set) var errorMessage: String?
    private(set) var screenshotErrorMessage: String?
    private(set) var screenshotPNGData: Data?
    private(set) var isLoadingScreenshot = false

    let context: IssueReportContext
    @ObservationIgnored private let reporter: any IssueReportSubmitting
    @ObservationIgnored private var screenshotLoadGeneration = 0

    init(
        context: IssueReportContext,
        reporter: any IssueReportSubmitting = SentryIssueReporter()
    ) {
        self.context = context
        self.reporter = reporter
    }

    var canSubmit: Bool {
        !trimmedMessage.isEmpty
            && message.count <= Self.maximumMessageLength
            && !isLoadingScreenshot
    }

    var screenshotImage: UIImage? {
        screenshotPNGData.flatMap(UIImage.init(data:))
    }

    func loadScreenshot(from item: PhotosPickerItem) async {
        screenshotLoadGeneration += 1
        let loadGeneration = screenshotLoadGeneration
        isLoadingScreenshot = true
        screenshotErrorMessage = nil

        defer {
            if loadGeneration == screenshotLoadGeneration {
                isLoadingScreenshot = false
            }
        }

        do {
            guard let selectedData = try await item.loadTransferable(type: Data.self) else {
                throw IssueReportError.screenshotUnavailable
            }
            let pngData = try await IssueReportScreenshotProcessor.makePNGData(from: selectedData)
            try Task.checkCancellation()
            guard loadGeneration == screenshotLoadGeneration else { return }
            screenshotPNGData = pngData
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == screenshotLoadGeneration else { return }
            screenshotErrorMessage = IssueReportError.screenshotUnavailable.localizedDescription
        }
    }

    func attachPreparedScreenshot(_ pngData: Data) {
        screenshotLoadGeneration += 1
        screenshotPNGData = pngData
        screenshotErrorMessage = nil
        isLoadingScreenshot = false
    }

    func removeScreenshot() {
        screenshotLoadGeneration += 1
        screenshotPNGData = nil
        screenshotErrorMessage = nil
        isLoadingScreenshot = false
    }

    func submit() {
        guard canSubmit else {
            errorMessage = IssueReportError.emptyMessage.localizedDescription
            return
        }

        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            referenceID = try reporter.submit(
                IssueReportSubmission(
                    message: trimmedMessage,
                    contactEmail: email.isEmpty ? nil : email,
                    context: context,
                    screenshotPNGData: screenshotPNGData
                )
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct IssueReportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IssueReportModel
    @State private var selectedScreenshotItem: PhotosPickerItem?

    @MainActor
    init(
        context: IssueReportContext = .current(),
        reporter: any IssueReportSubmitting = SentryIssueReporter()
    ) {
        _model = State(initialValue: IssueReportModel(context: context, reporter: reporter))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let referenceID = model.referenceID {
                    submittedContent(referenceID: referenceID)
                } else {
                    reportForm
                }
            }
            .navigationTitle("Report an issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.referenceID == nil {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                if model.referenceID == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send report") {
                            model.submit()
                        }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("issue-report-send")
                    }
                }
            }
            .alert(
                "Report could not be sent",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("OK") { model.dismissError() }
            } message: {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                }
            }
            .task(id: selectedScreenshotItem) {
                guard let selectedScreenshotItem else { return }
                await model.loadScreenshot(from: selectedScreenshotItem)
            }
        }
    }

    @ViewBuilder
    private var reportForm: some View {
        Section("Tell us what happened") {
            ZStack(alignment: .topLeading) {
                if model.message.isEmpty {
                    Text("What happened, and what did you expect?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.message)
                    .frame(minHeight: 150)
                    .accessibilityIdentifier("issue-report-message")
            }

            Text(verbatim: "\(model.message.count) / \(IssueReportModel.maximumMessageLength)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    model.message.count > IssueReportModel.maximumMessageLength
                        ? .red
                        : .secondary
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        }

        Section {
            TextField("Contact email (optional)", text: $model.contactEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("issue-report-email")
        }

        Section("Screenshot (optional)") {
            if let screenshotImage = model.screenshotImage {
                Image(uiImage: screenshotImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Selected screenshot")

                PhotosPicker(
                    selection: $selectedScreenshotItem,
                    matching: .screenshots,
                    preferredItemEncoding: .current
                ) {
                    Label("Choose another screenshot", systemImage: "photo.badge.plus")
                }

                Button("Remove screenshot", systemImage: "trash", role: .destructive) {
                    selectedScreenshotItem = nil
                    model.removeScreenshot()
                }
            } else if model.isLoadingScreenshot {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing screenshot…")
                        .foregroundStyle(.secondary)
                }
            } else {
                PhotosPicker(
                    selection: $selectedScreenshotItem,
                    matching: .screenshots,
                    preferredItemEncoding: .current
                ) {
                    Label("Choose screenshot from Photos", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("issue-report-choose-screenshot")
            }

            if let screenshotErrorMessage = model.screenshotErrorMessage {
                Label(screenshotErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("ComiNavi can access only the screenshot you choose.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Included diagnostics") {
            if let publicUserID = model.context.publicUserID {
                LabeledContent("ComiNavi account ID") {
                    Text(publicUserID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            LabeledContent("App installation ID") {
                Text(model.context.installationID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Label("App version, device model, and operating system", systemImage: "iphone")
            Label("Recent app actions and network breadcrumbs", systemImage: "list.bullet.rectangle")

            Text("Passwords, authentication tokens, and catalog contents are not included. A screenshot is attached only when you choose one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func submittedContent(referenceID: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Report queued")
                    .font(.title2.weight(.semibold))
                Text("Thanks. Your report and diagnostics have been queued for delivery.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }

        Section("Reference ID") {
            Text(referenceID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
