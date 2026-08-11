import Foundation
import XCTest
@testable import CominaviAPIClient

final class CominaviAPIClientTests: XCTestCase {
    func testGeneratedContractExposesSharedPlanListing() {
        XCTAssertEqual(Operations.ListSharedPlans.id, "listSharedPlans")
    }

    func testCheckedInContractMatchesServerGeneratedContractByteForByte() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let clientContract = packageRoot
            .appendingPathComponent("Sources/CominaviAPIClient/openapi.json")
        let serverContract = packageRoot
            .appendingPathComponent("../../../homepage/openapi/cominavi-openapi.json")
            .standardizedFileURL

        let clientData = try Data(contentsOf: clientContract)
        let serverData = try Data(contentsOf: serverContract)

        XCTAssertTrue(
            clientData == serverData,
            "The iOS OpenAPI contract has drifted from the server-generated contract."
        )
    }

    func testListSharedPlansInjectsBearerTokenAndUsesExpectedPath() async throws {
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        RequestCapturingURLProtocol.state.reset()
        defer {
            RequestCapturingURLProtocol.state.reset()
            session.invalidateAndCancel()
        }

        let client = CominaviAPIClientFactory.makeClient(
            serverURL: try XCTUnwrap(URL(string: "https://api.cominavi.test")),
            session: session,
            accessToken: { token }
        )

        let output = try await client.listSharedPlans()
        guard case .ok = output else {
            return XCTFail("Expected the fixture transport to return a successful response.")
        }

        let request = try XCTUnwrap(RequestCapturingURLProtocol.state.request())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v2/plans")
        XCTAssertNil(request.url?.query)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)",
            "The generated request did not use the token supplied by the provider."
        )
    }

    func testGeneratedClientDecodesCanonicalFractionalSecondDates() async throws {
        let serverURL = try XCTUnwrap(URL(string: "https://api.cominavi.test"))
        let client = CominaviAPIClientFactory.makeClient(
            serverURL: serverURL,
            transport: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url ?? serverURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ))
                let body = #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Plan","comiketNo":108,"role":"owner","status":"active","revision":1,"createdAt":"2026-08-09T12:05:00.000Z","updatedAt":"2026-08-09T12:05:00Z"}]}"#
                return (Data(body.utf8), response)
            }
        )

        let output = try await client.listSharedPlans()
        guard case .ok(let response) = output else {
            return XCTFail("Expected the generated client to decode the response.")
        }
        XCTAssertEqual(try response.body.json.items.count, 1)
    }
}

private final class RequestCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    func record(_ request: URLRequest) {
        lock.lock()
        capturedRequest = request
        lock.unlock()
    }

    func request() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    func reset() {
        lock.lock()
        capturedRequest = nil
        lock.unlock()
    }
}

private final class RequestCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = RequestCaptureState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.cominavi.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.record(request)

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"items":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
