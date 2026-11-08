#if DEBUG
// The feature is compiled only into Debug builds.
@testable import ComiNavi
import XCTest

final class CominaviTestSessionTests: XCTestCase {
    private let local = URL(string: "http://127.0.0.1:4380")!
    private let secret = ["COMINAVI_TEST_IDENTITY_SECRET": "local-dev-test-identity-secret-0123456789"]

    func testRequestIsAbsentWithoutTheLaunchArgument() throws {
        XCTAssertNil(try CominaviTestSession.request(
            arguments: ["ComiNavi", "-cominavi-demo-data"],
            environment: secret,
            serviceOrigin: local
        ))
    }

    func testRequestNeedsAValidLabelAndTheSecret() throws {
        let request = try CominaviTestSession.request(
            arguments: ["ComiNavi", "-cominavi-test-session", "agent-1"],
            environment: secret,
            serviceOrigin: local
        )
        XCTAssertEqual(request, .init(label: "agent-1", secret: secret.values.first!))

        XCTAssertThrowsError(try CominaviTestSession.request(
            arguments: ["ComiNavi", "-cominavi-test-session"],
            environment: secret,
            serviceOrigin: local
        )) { XCTAssertEqual($0 as? CominaviTestSession.Rejection, .missingLabel) }

        for label in ["", "-agent", "Agent", "agent_1", "agent 1", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try CominaviTestSession.request(
                arguments: ["ComiNavi", "-cominavi-test-session", label],
                environment: secret,
                serviceOrigin: local
            ), label) { XCTAssertEqual($0 as? CominaviTestSession.Rejection, .invalidLabel(label)) }
        }

        for environment in [[:], ["COMINAVI_TEST_IDENTITY_SECRET": ""]] {
            XCTAssertThrowsError(try CominaviTestSession.request(
                arguments: ["ComiNavi", "-cominavi-test-session", "agent-1"],
                environment: environment,
                serviceOrigin: local
            )) { XCTAssertEqual($0 as? CominaviTestSession.Rejection, .missingSecret) }
        }
    }

    func testOnlyLoopbackTestAndStagingOriginsAreAllowed() throws {
        for origin in [
            "http://127.0.0.1:4380", "http://localhost:8787", "https://[::1]:8443",
            "https://api.cominavi.test", "https://staging.cominavi.net",
        ] {
            XCTAssertTrue(CominaviTestSession.isAllowedOrigin(try XCTUnwrap(URL(string: origin))), origin)
        }
        for origin in [
            "https://cominavi.net", "https://cominavi.net:443", "https://example.com",
            "http://staging.cominavi.net", "http://api.cominavi.test", "https://cominavi.net.test.example",
        ] {
            XCTAssertFalse(CominaviTestSession.isAllowedOrigin(try XCTUnwrap(URL(string: origin))), origin)
        }
        XCTAssertThrowsError(try CominaviTestSession.request(
            arguments: ["ComiNavi", "-cominavi-test-session", "agent-1"],
            environment: secret,
            serviceOrigin: CominaviServiceOrigin.production
        )) {
            XCTAssertEqual(
                $0 as? CominaviTestSession.Rejection,
                .originNotAllowed("https://cominavi.net")
            )
        }
    }

    func testSignInPostsTheLabelAndPersistsTheSession() async throws {
        let transport = RecordingTransport(status: 200, body: Self.sessionJSON)
        let store = RecordingSessionStore()
        let client = CominaviServiceClient(
            baseURL: local,
            transport: { try await transport.respond(to: $0) },
            sessionStore: store
        )

        let session = try await client.authenticateWithTestIdentity(
            label: "agent-1",
            secret: "local-dev-test-identity-secret-0123456789"
        )

        let request = try await XCTUnwrapAsync(await transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4380/api/v2/auth/test/session")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-ComiNavi-Test-Identity-Secret"),
            "local-dev-test-identity-secret-0123456789"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, ["label": "agent-1"])

        XCTAssertEqual(session.user?.id, "01ba8df6196782b00620191e8e173c83")
        XCTAssertEqual(session.user?.displayName, "Test agent-1")
        XCTAssertEqual(session.refreshToken, "refresh-token")
        XCTAssertEqual(store.saved.last??.accessToken, "access-token")
        XCTAssertEqual(store.boundUserID, "01ba8df6196782b00620191e8e173c83")
        let profile = await client.storedUserProfile()
        XCTAssertEqual(profile?.id, "01ba8df6196782b00620191e8e173c83")
    }

    func testProductionOriginNeverSendsARequest() async throws {
        let transport = RecordingTransport(status: 200, body: Self.sessionJSON)
        let client = CominaviServiceClient(
            baseURL: CominaviServiceOrigin.production,
            transport: { try await transport.respond(to: $0) },
            sessionStore: RecordingSessionStore()
        )
        do {
            _ = try await client.authenticateWithTestIdentity(label: "agent-1", secret: "secret")
            XCTFail("production must refuse test sessions")
        } catch {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testServiceRefusalIsReportedAndNothingIsPersisted() async throws {
        let transport = RecordingTransport(
            status: 401,
            body: #"{"error":"invalid_test_identity_secret","message":"wrong"}"#
        )
        let store = RecordingSessionStore()
        let client = CominaviServiceClient(
            baseURL: local,
            transport: { try await transport.respond(to: $0) },
            sessionStore: store
        )
        do {
            _ = try await client.authenticateWithTestIdentity(label: "agent-1", secret: "wrong")
            XCTFail("a refused sign-in must throw")
        } catch {}
        XCTAssertTrue(store.saved.allSatisfy { $0 == nil })
    }

    private static let sessionJSON = """
    {"tokenType":"Bearer","authVersion":1,"accessToken":"access-token",
     "expiresAt":"\(iso(3_600))","refreshToken":"refresh-token",
     "refreshExpiresAt":"\(iso(86_400))",
     "user":{"id":"01ba8df6196782b00620191e8e173c83","displayName":"Test agent-1",
             "revision":1,"identities":[]}}
    """

    /// JavaScript `toISOString()` shape, with milliseconds.
    private static func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSinceNow: offset))
    }
}

private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T {
    try XCTUnwrap(value)
}

private actor RecordingTransport {
    let status: Int
    let body: String
    private(set) var requests: [URLRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }
}

private final class RecordingSessionStore: @unchecked Sendable,
    CominaviAuthenticationSessionPersisting
{
    private let lock = NSLock()
    private var sessions: [CominaviAuthenticationSession?] = []
    private var binding: String?

    var saved: [CominaviAuthenticationSession?] { lock.withLock { sessions } }
    var boundUserID: String? { lock.withLock { binding } }

    func load() -> CominaviAuthenticationSession? { lock.withLock { sessions.last ?? nil } }
    func save(_ session: CominaviAuthenticationSession?) -> Bool {
        lock.withLock { sessions.append(session) }
        return true
    }
    func loadBoundUserID() -> String? { boundUserID }
    func saveBoundUserID(_ userID: String?) -> Bool {
        lock.withLock { binding = userID }
        return true
    }
}
#endif
