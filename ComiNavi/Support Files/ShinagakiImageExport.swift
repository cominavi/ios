import Foundation
import UIKit
import UniformTypeIdentifiers

struct ShinagakiImageExportData: Sendable {
    let data: Data
    let sourceURL: URL?
}

struct ShinagakiImageExportPayload: Sendable {
    let fileURL: URL

    func removeTemporaryFile() {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        )
    }
}

extension ShinagakiLightboxPage {
    @MainActor
    func imageExportData() async -> ShinagakiImageExportData? {
        await imageExportData { url in
            await RemoteImagePipeline.imageData(
                for: url,
                category: .shinagaki
            )
        }
    }

    @MainActor
    func imageExportData(
        using dataLoader: (URL) async -> Data?
    ) async -> ShinagakiImageExportData? {
        var seen = Set<URL>()
        let sourceURLs = [originalURL, previewURL]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }

        for sourceURL in sourceURLs {
            guard !Task.isCancelled else { return nil }
            guard let data = await dataLoader(sourceURL), !data.isEmpty else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            return ShinagakiImageExportData(
                data: data,
                sourceURL: sourceURL
            )
        }

        guard let image,
              !Task.isCancelled,
              let data = await RemoteImagePipeline.encodedPNGData(for: image),
              !Task.isCancelled
        else { return nil }
        return ShinagakiImageExportData(data: data, sourceURL: nil)
    }

    @MainActor
    func imageExportPayload() async -> ShinagakiImageExportPayload? {
        guard let exportData = await imageExportData() else { return nil }
        return await ShinagakiImageExportWriter.payload(
            exportData: exportData,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
    }

    @MainActor
    func imageExportPayload(
        using dataLoader: (URL) async -> Data?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async -> ShinagakiImageExportPayload? {
        guard let exportData = await imageExportData(using: dataLoader) else {
            return nil
        }
        return await ShinagakiImageExportWriter.payload(
            exportData: exportData,
            temporaryDirectory: temporaryDirectory
        )
    }
}

private enum ShinagakiImageExportWriter {
    static func payload(
        exportData: ShinagakiImageExportData,
        temporaryDirectory: URL
    ) async -> ShinagakiImageExportPayload? {
        let data = exportData.data
        guard !Task.isCancelled else { return nil }

        let fileExtension = imageFileExtension(
            sourceURL: exportData.sourceURL,
            data: data
        ) ?? "png"
        let directoryURL = temporaryDirectory.appendingPathComponent(
            "cominavi-shinagaki-share-\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = directoryURL.appendingPathComponent(
            "shinagaki.\(fileExtension)",
            isDirectory: false
        )

        let writeTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                guard !Task.isCancelled else { return false }
                try data.write(to: fileURL, options: .atomic)
                return !Task.isCancelled
            } catch {
                return false
            }
        }

        let didWrite = await withTaskCancellationHandler {
            await writeTask.value
        } onCancel: {
            writeTask.cancel()
        }

        guard didWrite, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: directoryURL)
            return nil
        }
        return ShinagakiImageExportPayload(fileURL: fileURL)
    }

    private static func imageFileExtension(
        sourceURL: URL?,
        data: Data
    ) -> String? {
        detectedFileExtension(in: data)
            ?? sourceURL.flatMap(imageFileExtension(from:))
    }

    private static func imageFileExtension(from url: URL) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image)
        else { return nil }
        if type == .jpeg {
            return "jpg"
        }
        return type.preferredFilenameExtension ?? pathExtension
    }

    private static func detectedFileExtension(in data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if bytes.starts(with: Array("GIF87a".utf8))
            || bytes.starts(with: Array("GIF89a".utf8))
        {
            return "gif"
        }
        if bytes.count >= 12,
           Array(bytes[0 ..< 4]) == Array("RIFF".utf8),
           Array(bytes[8 ..< 12]) == Array("WEBP".utf8)
        {
            return "webp"
        }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        {
            return "tiff"
        }
        if bytes.starts(with: [0x42, 0x4D]) {
            return "bmp"
        }
        if bytes.count >= 12,
           Array(bytes[4 ..< 8]) == Array("ftyp".utf8)
        {
            let brand = String(decoding: bytes[8 ..< 12], as: UTF8.self)
            switch brand {
            case "avif", "avis":
                return "avif"
            case "heic", "heix", "hevc", "hevx", "mif1", "msf1":
                return "heic"
            default:
                break
            }
        }
        return nil
    }
}
