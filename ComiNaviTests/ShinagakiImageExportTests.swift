import XCTest
import UIKit
@testable import ComiNavi

final class ShinagakiImageExportTests: XCTestCase {
    @MainActor
    func testOriginalImageDataIsPreferred() async throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://example.com/artwork-original.jpg")
        )
        let previewURL = try XCTUnwrap(
            URL(string: "https://example.com/artwork-preview.png")
        )
        let originalData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33])
        let previewData = Data([0x89, 0x50, 0x4E, 0x47])
        let page = remotePage(originalURL: originalURL, previewURL: previewURL)
        let temporaryDirectory = try makeTemporaryDirectory(named: "original")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var attemptedURLs: [URL] = []

        let loadedPayload = await page.imageExportPayload(
            using: { url in
                attemptedURLs.append(url)
                return url == originalURL ? originalData : previewData
            },
            temporaryDirectory: temporaryDirectory
        )

        let payload = try XCTUnwrap(loadedPayload)
        XCTAssertEqual(attemptedURLs, [originalURL])
        XCTAssertEqual(payload.fileURL.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), originalData)
        payload.removeTemporaryFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.fileURL.path))
    }

    @MainActor
    func testPreviewImageDataIsUsedWhenOriginalFails() async throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://example.com/artwork-original.jpg")
        )
        let previewURL = try XCTUnwrap(
            URL(string: "https://example.com/artwork-preview.gif")
        )
        let previewData = Data("GIF89a-preview-payload".utf8)
        let page = remotePage(originalURL: originalURL, previewURL: previewURL)
        let temporaryDirectory = try makeTemporaryDirectory(named: "preview")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var attemptedURLs: [URL] = []

        let loadedPayload = await page.imageExportPayload(
            using: { url in
                attemptedURLs.append(url)
                return url == previewURL ? previewData : nil
            },
            temporaryDirectory: temporaryDirectory
        )

        let payload = try XCTUnwrap(loadedPayload)
        XCTAssertEqual(attemptedURLs, [originalURL, previewURL])
        XCTAssertEqual(payload.fileURL.pathExtension, "gif")
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), previewData)
        payload.removeTemporaryFile()
    }

    @MainActor
    func testLegacyImageIsEncodedAsPNGWithoutLoadingRemoteData() async throws {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 3, height: 2)
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        let page = ShinagakiLightboxPage(
            id: "legacy-image",
            image: image,
            accessibilityLabel: "Legacy image"
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "legacy")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var didLoadRemoteData = false

        let loadedPayload = await page.imageExportPayload(
            using: { _ in
                didLoadRemoteData = true
                return nil
            },
            temporaryDirectory: temporaryDirectory
        )

        let payload = try XCTUnwrap(loadedPayload)
        XCTAssertFalse(didLoadRemoteData)
        XCTAssertEqual(payload.fileURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), image.pngData())
        payload.removeTemporaryFile()
    }

    @MainActor
    func testVisibleRemoteImageFallsBackToPNGWhenRemoteBytesFail() async throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://example.com/unavailable-original.jpg")
        )
        let previewURL = try XCTUnwrap(
            URL(string: "https://example.com/unavailable-preview.jpg")
        )
        let visibleImage = UIGraphicsImageRenderer(
            size: CGSize(width: 5, height: 4)
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 5, height: 4))
        }
        let page = remotePage(
            originalURL: originalURL,
            previewURL: previewURL
        ).withInitialImage(visibleImage)
        var attemptedURLs: [URL] = []

        let exportData = await page.imageExportData { url in
            attemptedURLs.append(url)
            return nil
        }

        XCTAssertEqual(attemptedURLs, [originalURL, previewURL])
        XCTAssertEqual(exportData?.data, visibleImage.pngData())
        XCTAssertNil(exportData?.sourceURL)
    }

    @MainActor
    func testSavingDataDoesNotDependOnTemporaryFileAccess() async throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://example.com/artwork.jpg")
        )
        let originalData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let page = remotePage(originalURL: originalURL, previewURL: nil)

        let exportData = await page.imageExportData { _ in originalData }

        XCTAssertEqual(exportData?.data, originalData)
        XCTAssertEqual(exportData?.sourceURL, originalURL)
    }

    @MainActor
    func testVideoPageExportsOnlyItsStillPreview() async throws {
        let videoURL = try XCTUnwrap(
            URL(string: "https://example.com/movie.mp4")
        )
        let previewURL = try XCTUnwrap(
            URL(string: "https://example.com/movie-preview.jpg")
        )
        let previewData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let page = ShinagakiLightboxPage(
            id: "video-media",
            media: CatalogShinagakiMedia(
                kind: .video,
                url: videoURL,
                previewURL: previewURL
            ),
            accessibilityLabel: "Video preview"
        )
        var attemptedURLs: [URL] = []

        let exportData = await page.imageExportData { url in
            attemptedURLs.append(url)
            return previewData
        }

        XCTAssertEqual(attemptedURLs, [previewURL])
        XCTAssertEqual(exportData?.data, previewData)
        XCTAssertEqual(exportData?.sourceURL, previewURL)
    }

    @MainActor
    func testPayloadKeepsExactBytesAndUsesDetectedExtension() async throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "https://example.com/image.php?size=large")
        )
        let webPData = Data(
            Array("RIFF".utf8)
                + [0x04, 0x00, 0x00, 0x00]
                + Array("WEBP".utf8)
                + [0xDE, 0xAD, 0xBE, 0xEF]
        )
        let page = remotePage(originalURL: sourceURL, previewURL: nil)
        let temporaryDirectory = try makeTemporaryDirectory(named: "exact")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstLoadedPayload = await page.imageExportPayload(
            using: { _ in webPData },
            temporaryDirectory: temporaryDirectory
        )
        let secondLoadedPayload = await page.imageExportPayload(
            using: { _ in webPData },
            temporaryDirectory: temporaryDirectory
        )
        let firstPayload = try XCTUnwrap(firstLoadedPayload)
        let secondPayload = try XCTUnwrap(secondLoadedPayload)

        XCTAssertEqual(firstPayload.fileURL.pathExtension, "webp")
        XCTAssertNotEqual(firstPayload.fileURL, secondPayload.fileURL)
        XCTAssertEqual(try Data(contentsOf: firstPayload.fileURL), webPData)
        firstPayload.removeTemporaryFile()
        secondPayload.removeTemporaryFile()
    }

    @MainActor
    func testShareCoordinatorRemovesStagedFileExactlyOnce() async throws {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 4, height: 3)
        ).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let page = ShinagakiLightboxPage(
            id: "share-cleanup",
            image: image,
            accessibilityLabel: "Share cleanup"
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "share-cleanup")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let loadedPayload = await page.imageExportPayload(
            using: { _ in nil },
            temporaryDirectory: temporaryDirectory
        )
        let payload = try XCTUnwrap(loadedPayload)
        var completionCount = 0
        let coordinator = ShinagakiShareSheet.Coordinator(
            payload: payload,
            onCompletion: { completionCount += 1 }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.fileURL.path))
        coordinator.finish(notify: true)
        coordinator.finish(notify: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.fileURL.path))
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testShareSheetDismantleRemovesFileWithoutReportingCompletion() async throws {
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 4, height: 3)
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let page = ShinagakiLightboxPage(
            id: "share-dismantle",
            image: image,
            accessibilityLabel: "Share dismantle"
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "share-dismantle")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let loadedPayload = await page.imageExportPayload(
            using: { _ in nil },
            temporaryDirectory: temporaryDirectory
        )
        let payload = try XCTUnwrap(loadedPayload)
        var completionCount = 0
        let coordinator = ShinagakiShareSheet.Coordinator(
            payload: payload,
            onCompletion: { completionCount += 1 }
        )
        let controller = UIActivityViewController(
            activityItems: [payload.fileURL],
            applicationActivities: nil
        )

        ShinagakiShareSheet.dismantleUIViewController(
            controller,
            coordinator: coordinator
        )
        coordinator.finish(notify: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.fileURL.path))
        XCTAssertEqual(completionCount, 0)
    }

    private func remotePage(
        originalURL: URL,
        previewURL: URL?
    ) -> ShinagakiLightboxPage {
        ShinagakiLightboxPage(
            id: "remote-image",
            media: CatalogShinagakiMedia(
                kind: .photo,
                url: originalURL,
                previewURL: previewURL
            ),
            accessibilityLabel: "Remote image"
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ShinagakiImageExportTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
