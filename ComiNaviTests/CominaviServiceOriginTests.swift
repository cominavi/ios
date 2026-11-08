@testable import ComiNavi
import Foundation
import XCTest

final class CominaviServiceOriginTests: XCTestCase {
    private typealias Switch = CominaviServiceOriginSwitch

    // MARK: Validation

    func testAcceptsLoopbackStagingTestAndProductionOrigins() throws {
        let accepted: [(String, String)] = [
            ("http://127.0.0.1:8787", "http://127.0.0.1:8787"),
            ("http://127.0.0.1:8787/", "http://127.0.0.1:8787"),
            ("  HTTP://LOCALHOST:4321  ", "http://localhost:4321"),
            ("http://[::1]:8787", "http://[::1]:8787"),
            ("https://127.0.0.1", "https://127.0.0.1"),
            ("http://127.0.0.1:80", "http://127.0.0.1"),
            ("https://cominavi.test", "https://cominavi.test"),
            ("https://api.cominavi.test:8443", "https://api.cominavi.test:8443"),
            ("https://staging.cominavi.net", "https://staging.cominavi.net"),
            ("https://staging.cominavi.net:443/", "https://staging.cominavi.net"),
            ("https://cominavi.net", "https://cominavi.net"),
        ]
        for (raw, canonical) in accepted {
            XCTAssertEqual(try Switch.validate(raw).absoluteString, canonical, raw)
        }
    }

    func testRefusesEverythingElse() {
        let refused: [(String, Switch.Rejection)] = [
            ("", .missingValue),
            ("   ", .missingValue),
            ("https://example.com", .hostNotAllowed("example.com")),
            ("https://cominavi.net.example.com", .hostNotAllowed("cominavi.net.example.com")),
            ("https://evilcominavi.net", .hostNotAllowed("evilcominavi.net")),
            ("https://dev.cominavi.net", .hostNotAllowed("dev.cominavi.net")),
            ("http://192.168.1.10:8787", .hostNotAllowed("192.168.1.10")),
            ("http://10.0.0.1", .hostNotAllowed("10.0.0.1")),
            ("https://test", .hostNotAllowed("test")),
            ("https://cominavi.test.example.com", .hostNotAllowed("cominavi.test.example.com")),
            ("http://cominavi.test", .insecureScheme("cominavi.test")),
            ("http://cominavi.net", .insecureScheme("cominavi.net")),
            ("http://staging.cominavi.net", .insecureScheme("staging.cominavi.net")),
            ("https://cominavi.net:8443", .unexpectedPort("cominavi.net")),
            ("https://staging.cominavi.net:8443", .unexpectedPort("staging.cominavi.net")),
            ("ws://127.0.0.1:8787", .unsupportedScheme("ws")),
            ("file:///tmp", .malformed),
            ("http://127.0.0.1:8787/api", .notAnOrigin),
            ("http://127.0.0.1:8787?x=1", .notAnOrigin),
            ("http://127.0.0.1:8787#x", .notAnOrigin),
            ("http://user:pass@127.0.0.1:8787", .notAnOrigin),
        ]
        for (raw, rejection) in refused {
            XCTAssertThrowsError(try Switch.validate(raw), raw) { error in
                XCTAssertEqual(error as? Switch.Rejection, rejection, raw)
            }
        }
        // Not absolute URLs at all.
        for raw in ["127.0.0.1:8787", "cominavi.net", "//127.0.0.1:8787"] {
            XCTAssertThrowsError(try Switch.validate(raw), raw)
        }
    }

    // MARK: Request resolution

    func testLaunchArgumentWinsOverEnvironmentAndConfiguredDefault() throws {
        let configured = "https://cominavi.net"
        XCTAssertEqual(
            try Switch.resolve(configured: configured, arguments: ["ComiNavi"], environment: [:]),
            CominaviServiceOrigin.production
        )
        XCTAssertEqual(
            try Switch.resolve(
                configured: configured,
                arguments: ["ComiNavi"],
                environment: [Switch.environmentVariable: "http://127.0.0.1:9000"]
            ).absoluteString,
            "http://127.0.0.1:9000"
        )
        XCTAssertEqual(
            try Switch.resolve(
                configured: configured,
                arguments: ["ComiNavi", "-cominavi-service-origin", "http://127.0.0.1:8787"],
                environment: [Switch.environmentVariable: "http://127.0.0.1:9000"]
            ).absoluteString,
            "http://127.0.0.1:8787"
        )
    }

    func testInvalidRequestIsRefusedInsteadOfFallingBackToProduction() {
        XCTAssertThrowsError(try Switch.resolve(
            configured: "https://cominavi.net",
            arguments: ["ComiNavi", "-cominavi-service-origin"],
            environment: [:]
        )) { error in
            XCTAssertEqual(error as? Switch.Rejection, .missingValue)
        }
        XCTAssertThrowsError(try Switch.resolve(
            configured: "https://cominavi.net",
            arguments: ["ComiNavi"],
            environment: [Switch.environmentVariable: "https://example.com"]
        ))
        XCTAssertThrowsError(try Switch.resolve(
            configured: "https://example.com",
            arguments: ["ComiNavi"],
            environment: [:]
        ))
    }

    func testTheTestHostUsesProductionWithoutAnOverride() {
        // The unit-test host launches without the switch, so everything that
        // reads `AppEnvironment.current` keeps its production behavior.
        XCTAssertTrue(CominaviServiceOrigin.isProduction(AppEnvironment.current.serviceOrigin))
        XCTAssertEqual(
            DemoCatalogSource.remoteBaseURL.absoluteString,
            "https://cominavi.net/api/v2/review-demo/catalogs/c104/v2"
        )
    }

    // MARK: Storage isolation

    func testProductionKeepsItsExistingNamespace() {
        XCTAssertNil(CominaviServiceOrigin.storageComponent(for: CominaviServiceOrigin.production))
        XCTAssertEqual(
            AppEnvironment.storageNamespace(
                build: .debug,
                circlems: .production,
                serviceOrigin: CominaviServiceOrigin.production
            ),
            "pre-release-v2/debug/production"
        )
        XCTAssertEqual(
            AppEnvironment.storageDirectoryComponents(
                build: .staging,
                circlems: .testing,
                serviceOrigin: CominaviServiceOrigin.production
            ),
            ["staging", "testing"]
        )
    }

    func testEveryOriginGetsItsOwnNamespaceAndDirectories() throws {
        let origins = try [
            "https://cominavi.net",
            "http://127.0.0.1:8787",
            "http://127.0.0.1:8788",
            "https://127.0.0.1:8787",
            "http://localhost:8787",
            "http://[::1]:8787",
            "https://cominavi.test",
            "https://staging.cominavi.net",
        ].map(Switch.validate)

        let namespaces = origins.map {
            AppEnvironment.storageNamespace(build: .debug, circlems: .production, serviceOrigin: $0)
        }
        XCTAssertEqual(Set(namespaces).count, origins.count, "\(namespaces)")
        XCTAssertEqual(
            namespaces[1],
            "pre-release-v2/debug/production/origin-http-127.0.0.1-8787"
        )
        XCTAssertEqual(
            namespaces[5],
            "pre-release-v2/debug/production/origin-http-__1-8787"
        )

        let directories = origins.map {
            AppEnvironment.storageDirectoryComponents(
                build: .debug,
                circlems: .production,
                serviceOrigin: $0
            )
        }
        XCTAssertEqual(Set(directories).count, origins.count)
        for components in directories {
            XCTAssertTrue(components.allSatisfy {
                !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".."
            }, "\(components)")
        }
    }

    func testKeychainSessionsAreBoundToTheirOrigin() throws {
        // Two unused loopback ports stand in for "local" and "another local".
        // The production namespace is only read, never written.
        let localA = try Switch.validate("http://127.0.0.1:65001")
        let localB = try Switch.validate("http://127.0.0.1:65002")
        func store(_ origin: URL) -> KeychainCominaviAuthenticationSessionStore {
            KeychainCominaviAuthenticationSessionStore(account: AppEnvironment.storageNamespace(
                build: .debug,
                circlems: .production,
                serviceOrigin: origin
            ))
        }
        let storeA = store(localA)
        let storeB = store(localB)
        let production = store(CominaviServiceOrigin.production)
        defer {
            storeA.save(nil)
            storeB.save(nil)
        }

        let session = CominaviAuthenticationSession(
            accessToken: "origin-isolation-access-\(UUID().uuidString)",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            refreshToken: "origin-isolation-refresh",
            refreshExpiresAt: Date(timeIntervalSinceNow: 86_400)
        )
        XCTAssertTrue(storeA.save(session))
        // The store encodes dates as whole-second ISO 8601, so compare tokens.
        XCTAssertEqual(storeA.load()?.accessToken, session.accessToken)
        XCTAssertNil(storeB.load())
        XCTAssertNotEqual(production.load()?.accessToken, session.accessToken)

        XCTAssertTrue(storeA.saveBoundUserID("origin-isolation-user"))
        XCTAssertNil(storeB.loadBoundUserID())
        XCTAssertNotEqual(production.loadBoundUserID(), "origin-isolation-user")
        storeA.saveBoundUserID(nil)
    }

    func testAuthenticatedImageCacheKeysAreBoundToTheOrigin() throws {
        let avatar = try XCTUnwrap(URL(string: "/api/v2/users/0123456789abcdef0123456789abcdef/avatar"))
        let production = RemoteImagePipeline.authenticatedCacheKey(
            for: avatar,
            revision: 3,
            serviceOrigin: CominaviServiceOrigin.production
        )
        let local = RemoteImagePipeline.authenticatedCacheKey(
            for: avatar,
            revision: 3,
            serviceOrigin: try Switch.validate("http://127.0.0.1:4380")
        )
        let otherLocal = RemoteImagePipeline.authenticatedCacheKey(
            for: avatar,
            revision: 3,
            serviceOrigin: try Switch.validate("http://127.0.0.1:4381")
        )
        XCTAssertEqual(
            production,
            "authenticated:/api/v2/users/0123456789abcdef0123456789abcdef/avatar#3"
        )
        XCTAssertEqual(Set([production, local, otherLocal]).count, 3)
        XCTAssertEqual(
            RemoteImagePipeline.authenticatedCacheKey(for: avatar, revision: 3),
            production
        )
    }

    // MARK: Downloads

    func testPlainHTTPDownloadsAreAllowedOnlyOnTheLoopbackServiceOrigin() throws {
        let local = try Switch.validate("http://127.0.0.1:4380")
        let production = CominaviServiceOrigin.production
        let artifact = try XCTUnwrap(URL(string: "http://127.0.0.1:4380/api/v2/review-demo/catalogs/c104/v2/main.sqlite.gz"))
        let secure = try XCTUnwrap(URL(string: "https://example.com/main.sqlite.gz"))

        XCTAssertTrue(CominaviServiceOrigin.isAllowedDownloadURL(secure, serviceOrigin: production))
        XCTAssertTrue(CominaviServiceOrigin.isAllowedDownloadURL(secure, serviceOrigin: local))
        XCTAssertTrue(CominaviServiceOrigin.isAllowedDownloadURL(artifact, serviceOrigin: local))
        XCTAssertFalse(CominaviServiceOrigin.isAllowedDownloadURL(artifact, serviceOrigin: production))
        XCTAssertFalse(CominaviServiceOrigin.isAllowedDownloadURL(
            try XCTUnwrap(URL(string: "http://127.0.0.1:4381/main.sqlite.gz")),
            serviceOrigin: local
        ))
        XCTAssertFalse(CominaviServiceOrigin.isAllowedDownloadURL(
            try XCTUnwrap(URL(string: "http://example.com/main.sqlite.gz")),
            serviceOrigin: local
        ))
        XCTAssertFalse(CominaviServiceOrigin.isAllowedDownloadURL(
            try XCTUnwrap(URL(string: "ftp://127.0.0.1:4380/main.sqlite.gz")),
            serviceOrigin: local
        ))
    }

    // MARK: Client wiring

    func testClientSendsRequestsOnlyToItsOrigin() async throws {
        let origin = try Switch.validate("http://127.0.0.1:8787")
        let recorder = RequestRecorder()
        let client = CominaviServiceClient(
            baseURL: origin,
            transport: { request in
                await recorder.record(request)
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":{"code":"unavailable","message":"test"}}"#.utf8), response)
            }
        )

        // A public, unauthenticated endpoint, so the request is really sent.
        _ = try? await client.realtimeUpdates(
            eventNumber: 108,
            afterCursor: 0,
            publicationRevision: "none",
            tagRevision: nil
        )

        let requests = await recorder.requests
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 8787)
        }
    }

    func testSpecialEntryPagesBelongToTheConfiguredOrigin() throws {
        let nonce = String(repeating: "A", count: 43)
        if let google = GoogleSpecialEntryLink.authorizationURL(nonce: nonce) {
            XCTAssertEqual(google.host, AppEnvironment.current.serviceOrigin.host)
            XCTAssertEqual(google.path, "/auth/google")
        }
        if let apple = AppleSpecialEntryLink.authorizationURL(nonce: nonce) {
            XCTAssertEqual(apple.host, AppEnvironment.current.serviceOrigin.host)
            XCTAssertEqual(apple.path, "/auth/apple")
        }
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}
