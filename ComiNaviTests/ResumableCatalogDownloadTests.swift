import Foundation
import XCTest
@testable import ComiNavi

final class ResumableCatalogDownloadTests: XCTestCase {
    func testTransientFailureResumesFromPersistedData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpointURL = directory.appendingPathComponent("main.resume-data")
        let downloadedURL = directory.appendingPathComponent("downloaded.gz")
        try Data("complete".utf8).write(to: downloadedURL)
        let partialData = Data("partial-resume-data".utf8)
        let transport = ScriptedCatalogDownloadTransport(steps: [
            .failure(resumeData: partialData, isTransient: true),
            .success(downloadedURL),
        ])
        let downloader = ResumableCatalogDownload(
            transport: transport,
            retryDelay: .zero
        )

        let result = try await downloader.download(
            from: URL(string: "https://example.com/catalog.gz")!,
            checkpointURL: checkpointURL
        ) { _, _ in }

        XCTAssertEqual(result, downloadedURL)
        let attempts = await transport.attemptedResumeData
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0])
        XCTAssertEqual(attempts[1], partialData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    func testRejectedStoredResumeDataFallsBackToFreshDownloadOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpointURL = directory.appendingPathComponent("image.resume-data")
        let staleResumeData = Data("stale-resume-data".utf8)
        try staleResumeData.write(to: checkpointURL)
        let downloadedURL = directory.appendingPathComponent("downloaded.gz")
        try Data("complete".utf8).write(to: downloadedURL)
        let transport = ScriptedCatalogDownloadTransport(steps: [
            .failure(resumeData: nil, isTransient: false),
            .success(downloadedURL),
        ])
        let downloader = ResumableCatalogDownload(
            transport: transport,
            retryDelay: .zero
        )

        _ = try await downloader.download(
            from: URL(string: "https://example.com/catalog.gz")!,
            checkpointURL: checkpointURL
        ) { _, _ in }

        let attempts = await transport.attemptedResumeData
        XCTAssertEqual(attempts, [staleResumeData, nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    func testCancellationKeepsProducedResumeData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpointURL = directory.appendingPathComponent("main.resume-data")
        let partialData = Data("cancelled-resume-data".utf8)
        let transport = ScriptedCatalogDownloadTransport(steps: [
            .cancellation(resumeData: partialData),
        ])
        let downloader = ResumableCatalogDownload(
            transport: transport,
            retryDelay: .zero
        )

        do {
            _ = try await downloader.download(
                from: URL(string: "https://example.com/catalog.gz")!,
                checkpointURL: checkpointURL
            ) { _, _ in }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: checkpointURL), partialData)
        }
    }

    func testFreshPermanentFailureDoesNotLoop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpointURL = directory.appendingPathComponent("main.resume-data")
        let transport = ScriptedCatalogDownloadTransport(steps: [
            .failure(resumeData: nil, isTransient: false),
        ])
        let downloader = ResumableCatalogDownload(
            transport: transport,
            retryDelay: .zero
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await downloader.download(
                from: URL(string: "https://example.com/catalog.gz")!,
                checkpointURL: checkpointURL
            ) { _, _ in }
        }

        let attempts = await transport.attemptedResumeData
        XCTAssertEqual(attempts.count, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cominavi-resume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor ScriptedCatalogDownloadTransport: CatalogDownloadTransporting {
    enum Step: Sendable {
        case success(URL)
        case failure(resumeData: Data?, isTransient: Bool)
        case cancellation(resumeData: Data?)
    }

    private var steps: [Step]
    private(set) var attemptedResumeData: [Data?] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func download(
        from _: URL,
        resumeData: Data?,
        progressHandler _: @escaping @Sendable (Int64, Int64) -> Void,
        resumeDataHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> URL {
        attemptedResumeData.append(resumeData)
        let step = steps.removeFirst()
        switch step {
        case .success(let url):
            return url
        case .failure(let producedResumeData, let isTransient):
            if let producedResumeData {
                resumeDataHandler(producedResumeData)
            }
            throw CatalogDownloadAttemptError(
                underlyingError: URLError(.networkConnectionLost),
                resumeData: producedResumeData,
                isTransient: isTransient
            )
        case .cancellation(let producedResumeData):
            if let producedResumeData {
                resumeDataHandler(producedResumeData)
            }
            throw CancellationError()
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
