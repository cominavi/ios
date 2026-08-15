import Foundation
import Photos

enum ShinagakiPhotoSaveStatus: Equatable, Sendable {
    case saved
    case permissionDenied
    case restricted
    case failed
    case cancelled
}

struct ShinagakiPhotoSaver: Sendable {
    typealias AuthorizationRequester = @Sendable () async -> PHAuthorizationStatus
    typealias ChangePerformer = @Sendable (Data) async throws -> Void

    private let requestAuthorization: AuthorizationRequester
    private let performChanges: ChangePerformer

    init(
        requestAuthorization: @escaping AuthorizationRequester = {
            await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        },
        performChanges: @escaping ChangePerformer = { imageData in
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(
                    with: .photo,
                    data: imageData,
                    options: nil
                )
            }
        }
    ) {
        self.requestAuthorization = requestAuthorization
        self.performChanges = performChanges
    }

    func save(_ imageData: Data) async -> ShinagakiPhotoSaveStatus {
        guard !Task.isCancelled else { return .cancelled }
        switch await requestAuthorization() {
        case .authorized, .limited:
            break
        case .restricted:
            return .restricted
        case .denied, .notDetermined:
            return .permissionDenied
        @unknown default:
            return .permissionDenied
        }

        // Cancellation can arrive while the system authorization prompt is
        // visible. Do not begin an irreversible PhotoKit transaction after
        // the initiating lightbox has gone away.
        guard !Task.isCancelled else { return .cancelled }
        do {
            try await performChanges(imageData)
            return .saved
        } catch {
            return .failed
        }
    }
}
