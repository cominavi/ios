import Photos
import XCTest
@testable import ComiNavi

final class ShinagakiPhotoSaverTests: XCTestCase {
    func testSaveStatusesMapToUserVisibleAlerts() {
        XCTAssertEqual(
            ShinagakiLightboxAlert(saveStatus: .saved),
            .saved
        )
        XCTAssertEqual(
            ShinagakiLightboxAlert(saveStatus: .permissionDenied),
            .photoAccessRequired
        )
        XCTAssertEqual(
            ShinagakiLightboxAlert(saveStatus: .restricted),
            .photoAccessRequired
        )
        XCTAssertEqual(
            ShinagakiLightboxAlert(saveStatus: .failed),
            .saveFailed
        )
        XCTAssertEqual(
            ShinagakiLightboxAlert(saveStatus: .cancelled),
            .saveFailed
        )
        XCTAssertEqual(
            ShinagakiLightboxAlert.photoAccessRequired.message,
            String(localized: "Photo access is required to save images")
        )
    }

    func testAuthorizedSavePassesRawImageDataToPhotoLibrary() async {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let spy = PhotoLibrarySpy(authorizationStatus: .authorized)
        let saver = makeSaver(spy: spy)

        let status = await saver.save(imageData)
        let savedData = await spy.savedData

        XCTAssertEqual(status, .saved)
        XCTAssertEqual(savedData, [imageData])
    }

    func testLimitedAuthorizationIsAllowedDefensively() async {
        let imageData = Data([0x01])
        let spy = PhotoLibrarySpy(authorizationStatus: .limited)
        let saver = makeSaver(spy: spy)

        let status = await saver.save(imageData)
        let savedData = await spy.savedData

        XCTAssertEqual(status, .saved)
        XCTAssertEqual(savedData, [imageData])
    }

    func testDeniedAuthorizationDoesNotAttemptPhotoLibraryChanges() async {
        let spy = PhotoLibrarySpy(authorizationStatus: .denied)
        let saver = makeSaver(spy: spy)

        let status = await saver.save(Data([0x01]))
        let savedData = await spy.savedData

        XCTAssertEqual(status, .permissionDenied)
        XCTAssertTrue(savedData.isEmpty)
    }

    func testRestrictedAuthorizationDoesNotAttemptPhotoLibraryChanges() async {
        let spy = PhotoLibrarySpy(authorizationStatus: .restricted)
        let saver = makeSaver(spy: spy)

        let status = await saver.save(Data([0x01]))
        let savedData = await spy.savedData

        XCTAssertEqual(status, .restricted)
        XCTAssertTrue(savedData.isEmpty)
    }

    func testPhotoLibraryFailureReturnsFailed() async {
        let imageData = Data([0x01])
        let spy = PhotoLibrarySpy(
            authorizationStatus: .authorized,
            performChangesError: PhotoLibrarySpy.ExpectedError()
        )
        let saver = makeSaver(spy: spy)

        let status = await saver.save(imageData)
        let savedData = await spy.savedData

        XCTAssertEqual(status, .failed)
        XCTAssertEqual(savedData, [imageData])
    }

    func testCancellationDuringAuthorizationDoesNotStartPhotoLibraryChanges() async {
        let authorization = SuspendedPhotoAuthorization()
        let spy = PhotoLibrarySpy(authorizationStatus: .authorized)
        let saver = ShinagakiPhotoSaver(
            requestAuthorization: {
                await authorization.request()
            },
            performChanges: { imageData in
                try await spy.performChanges(with: imageData)
            }
        )

        let task = Task {
            await saver.save(Data([0x01]))
        }
        await authorization.waitUntilRequested()
        task.cancel()
        await authorization.resume(with: .authorized)

        let status = await task.value
        let savedData = await spy.savedData
        XCTAssertEqual(status, .cancelled)
        XCTAssertTrue(savedData.isEmpty)
    }

    private func makeSaver(spy: PhotoLibrarySpy) -> ShinagakiPhotoSaver {
        ShinagakiPhotoSaver(
            requestAuthorization: {
                await spy.requestAuthorization()
            },
            performChanges: { imageData in
                try await spy.performChanges(with: imageData)
            }
        )
    }
}

private actor SuspendedPhotoAuthorization {
    private var authorizationContinuation:
        CheckedContinuation<PHAuthorizationStatus, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func request() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        guard authorizationContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume(with status: PHAuthorizationStatus) {
        authorizationContinuation?.resume(returning: status)
        authorizationContinuation = nil
    }
}

private actor PhotoLibrarySpy {
    struct ExpectedError: Error {}

    let authorizationStatus: PHAuthorizationStatus
    let performChangesError: Error?
    private(set) var savedData: [Data] = []

    init(
        authorizationStatus: PHAuthorizationStatus,
        performChangesError: Error? = nil
    ) {
        self.authorizationStatus = authorizationStatus
        self.performChangesError = performChangesError
    }

    func requestAuthorization() -> PHAuthorizationStatus {
        authorizationStatus
    }

    func performChanges(with imageData: Data) throws {
        savedData.append(imageData)
        if let performChangesError {
            throw performChangesError
        }
    }
}
