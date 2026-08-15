import Foundation
import Sentry

enum AppDiagnostics {
    static func addBreadcrumb(
        _ message: String,
        category: String,
        level: SentryLevel = .info,
        data: [String: Any] = [:]
    ) {
        let breadcrumb = Breadcrumb(level: level, category: category)
        breadcrumb.message = message
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func captureFollowingImportFailure(
        _ error: Error? = nil,
        stage: String,
        eventName: String? = nil,
        dataByteCount: Int? = nil
    ) {
        SentrySDK.capture(event: followingImportFailureEvent(
            error,
            stage: stage,
            eventName: eventName,
            dataByteCount: dataByteCount
        ))
    }

    static func followingImportFailureEvent(
        _ error: Error? = nil,
        stage: String,
        eventName: String? = nil,
        dataByteCount: Int? = nil
    ) -> Event {
        let diagnostic = followingImportDiagnostic(for: error)
        let capturedError = error.map { $0 as NSError } ?? NSError(
            domain: "net.cominavi.following-import",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The X following import response was invalid at \(stage).",
            ]
        )
        let event = Event(error: capturedError)
        event.logger = "following_import"
        event.transaction = "FollowingImport.importXFollowings"
        event.tags = [
            "feature": "x_following_import",
            "failure_stage": stage,
            "stream_event": eventName ?? "none",
            "error_kind": diagnostic.kind,
        ]
        event.fingerprint = [
            "x-following-import-invalid-response",
            stage,
            diagnostic.kind,
        ]

        var extra: [String: Any] = [
            "error_type": diagnostic.type,
        ]
        if let eventName {
            extra["stream_event"] = eventName
        }
        if let dataByteCount {
            extra["data_byte_count"] = dataByteCount
        }
        if let codingPath = diagnostic.codingPath {
            extra["coding_path"] = codingPath
        }
        if let debugDescription = diagnostic.debugDescription {
            extra["debug_description"] = debugDescription
        }
        event.extra = extra
        return event
    }

    private static func followingImportDiagnostic(
        for error: Error?
    ) -> (
        kind: String,
        type: String,
        codingPath: String?,
        debugDescription: String?
    ) {
        guard let error else {
            return ("invalid_response", "none", nil, nil)
        }

        let type = String(reflecting: Swift.type(of: error))
        switch error {
        case DecodingError.dataCorrupted(let context):
            return decodingDiagnostic(
                kind: "data_corrupted",
                type: type,
                context: context
            )
        case DecodingError.keyNotFound(let key, let context):
            return decodingDiagnostic(
                kind: "key_not_found",
                type: type,
                context: context,
                terminalKey: key.stringValue
            )
        case DecodingError.typeMismatch(_, let context):
            return decodingDiagnostic(
                kind: "type_mismatch",
                type: type,
                context: context
            )
        case DecodingError.valueNotFound(_, let context):
            return decodingDiagnostic(
                kind: "value_not_found",
                type: type,
                context: context
            )
        default:
            return ("other", type, nil, nil)
        }
    }

    private static func decodingDiagnostic(
        kind: String,
        type: String,
        context: DecodingError.Context,
        terminalKey: String? = nil
    ) -> (
        kind: String,
        type: String,
        codingPath: String?,
        debugDescription: String?
    ) {
        var path = context.codingPath.map(\.stringValue)
        if let terminalKey {
            path.append(terminalKey)
        }
        return (
            kind,
            type,
            path.isEmpty ? "<root>" : path.joined(separator: "."),
            context.debugDescription
        )
    }
}
