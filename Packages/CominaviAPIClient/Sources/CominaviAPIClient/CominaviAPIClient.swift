import Foundation
import HTTPTypes
import HTTPTypesFoundation
import OpenAPIRuntime
import OpenAPIURLSession

public typealias CominaviAccessTokenProvider = @Sendable () async throws -> String?
public typealias CominaviURLRequestTransport = @Sendable (URLRequest) async throws -> (
    Data,
    URLResponse
)

private struct CanonicalRFC3339DateTranscoder: DateTranscoder {
    private let fractional = ISO8601DateTranscoder(
        options: [.withInternetDateTime, .withFractionalSeconds]
    )
    private let standard = ISO8601DateTranscoder()

    func encode(_ date: Date) throws -> String {
        try fractional.encode(date)
    }

    func decode(_ value: String) throws -> Date {
        do {
            return try fractional.decode(value)
        } catch {
            return try standard.decode(value)
        }
    }
}

public enum CominaviAPIClientFactory {
    public static func makeClient(
        serverURL: URL,
        session: URLSession = .shared,
        accessToken: @escaping CominaviAccessTokenProvider = { nil }
    ) -> Client {
        Client(
            serverURL: serverURL,
            configuration: .init(dateTranscoder: CanonicalRFC3339DateTranscoder()),
            transport: URLSessionTransport(
                configuration: .init(session: session)
            ),
            middlewares: [
                BearerAuthenticationMiddleware(accessToken: accessToken),
                ProfileRevisionHeaderMiddleware(),
            ]
        )
    }

    /// Builds the generated client on top of the app's existing injected
    /// URLRequest transport. This keeps deterministic wire tests while call
    /// sites migrate away from handwritten request and response DTOs.
    public static func makeClient(
        serverURL: URL,
        transport: @escaping CominaviURLRequestTransport,
        accessToken: @escaping CominaviAccessTokenProvider = { nil }
    ) -> Client {
        Client(
            serverURL: serverURL,
            configuration: .init(dateTranscoder: CanonicalRFC3339DateTranscoder()),
            transport: URLRequestClosureTransport(sendRequest: transport),
            middlewares: [
                BearerAuthenticationMiddleware(accessToken: accessToken),
                ProfileRevisionHeaderMiddleware(),
            ]
        )
    }
}

private enum URLRequestClosureTransportError: Error {
    case invalidRequestURL
    case invalidResponse
}

private struct URLRequestClosureTransport: ClientTransport {
    private static let maximumBufferedRequestBytes = 16 * 1024 * 1024

    let sendRequest: CominaviURLRequestTransport

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: request.path ?? "")
        else { throw URLRequestClosureTransportError.invalidRequestURL }
        components.percentEncodedPath += relative.percentEncodedPath
        components.percentEncodedQuery = relative.percentEncodedQuery
        guard let url = components.url else {
            throw URLRequestClosureTransportError.invalidRequestURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        var headers: [String: String] = [:]
        for field in request.headerFields {
            if let existing = headers[field.name.rawName] {
                let separator = field.name == .cookie ? "; " : ", "
                headers[field.name.rawName] = existing + separator + field.value
            } else {
                headers[field.name.rawName] = field.value
            }
        }
        urlRequest.allHTTPHeaderFields = headers
        if let body {
            urlRequest.httpBody = try await Data(
                collecting: body,
                upTo: Self.maximumBufferedRequestBytes
            )
        }

        let (data, response) = try await sendRequest(urlRequest)
        guard let http = response as? HTTPURLResponse,
              let typedResponse = http.httpResponse
        else { throw URLRequestClosureTransportError.invalidResponse }
        let responseBody = data.isEmpty
            ? nil
            : HTTPBody(data)
        return (typedResponse, responseBody)
    }
}

private struct BearerAuthenticationMiddleware: ClientMiddleware {
    let accessToken: CominaviAccessTokenProvider

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
            HTTPResponse,
            HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = try await accessToken() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}

/// Swift OpenAPI Runtime URI-encodes string header parameters, including the
/// quotes and colon required by the profile `If-Match` tag. Restore that one
/// domain-specific header before it reaches the HTTP transport.
private struct ProfileRevisionHeaderMiddleware: ClientMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
            HTTPResponse,
            HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let encoded = request.headerFields[.ifMatch],
           let decoded = encoded.removingPercentEncoding,
           Self.isCanonicalProfileRevision(decoded)
        {
            request.headerFields[.ifMatch] = decoded
        }
        return try await next(request, body, baseURL)
    }

    private static func isCanonicalProfileRevision(_ value: String) -> Bool {
        let prefix = "\"profile:"
        guard value.hasPrefix(prefix), value.hasSuffix("\"") else { return false }
        let revision = value.dropFirst(prefix.count).dropLast()
        return revision.first?.isNumber == true
            && revision.first != "0"
            && revision.allSatisfy(\.isNumber)
    }
}
