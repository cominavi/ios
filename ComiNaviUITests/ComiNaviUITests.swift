//
//  ComiNaviUITests.swift
//  ComiNaviUITests
//
//  Created by Galvin Gao on 10/16/24.
//

import XCTest

final class ComiNaviUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLaunch() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Wait for app to become idle and take a screenshot
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        takeScreenshot(named: "MainView")
    }

    @MainActor
    func testSharedPlanRowReopensAfterReturningFromInvitations() throws {
        let planID = "11111111-1111-4111-8111-111111111111"
        let app = XCUIApplication()
        app.launchArguments += [
            "-cominavi-ui-testing-hide-debugger",
            "-cominavi-ui-testing-shared-plan-list",
        ]
        app.launch()

        for _ in 0 ..< 5 {
            let row = app.buttons["shared-plan-row-\(planID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(
                app.images["shared-plan-row-icon-\(planID)"].exists,
                "Every Shared Plan row needs a visible plan icon"
            )
            row.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["shared-plan-test-detail"]
                    .waitForExistence(timeout: 5),
                "Tapping a plan must navigate to its detail"
            )

            let invitations = app.buttons["shared-plan-open-management"]
            XCTAssertTrue(invitations.waitForExistence(timeout: 5))
            invitations.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["shared-plan-test-invitations"]
                    .waitForExistence(timeout: 5),
                "The invitations page must be pushed onto the navigation stack"
            )

            let invitationBackButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(invitationBackButton.waitForExistence(timeout: 5))
            invitationBackButton.tap()

            let planBackButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(planBackButton.waitForExistence(timeout: 5))
            planBackButton.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testSharedPlanNotificationsOpenFromPlanToolbar() {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-ui-testing-no-catalog-shell")
        app.launch()

        let notificationsButton = app.buttons["shared-plan-notifications-button"]
        XCTAssertTrue(notificationsButton.waitForExistence(timeout: 5))
        notificationsButton.tap()

        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shared-plan-notifications-done"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["shared-plan-notifications-sheet"].exists)

        app.buttons["shared-plan-notifications-done"].tap()
        XCTAssertFalse(app.navigationBars["Notifications"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSharedPlanPurchaseRowsShowFiveCompactThreeStageRequests() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-cominavi-ui-testing-hide-debugger",
            "-cominavi-ui-testing-shared-plan-purchases",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["shared-plan-purchase-test-surface"]
                .waitForExistence(timeout: 8)
        )

        var rowHeights: [CGFloat] = []
        for index in 1 ... 5 {
            let id = String(format: "10000000-0000-4000-8000-%012d", index)
            let row = app.descendants(matching: .any)["shared-plan-editor-need-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Request \(index) must be visible")
            rowHeights.append(row.frame.height)
            XCTAssertTrue(
                app.descendants(matching: .any)["shared-plan-editor-need-progress-\(id)"].exists,
                "Request \(index) must show requested, assigned, and bought progress"
            )
        }

        guard let expectedRowHeight = rowHeights.first else {
            return XCTFail("Purchase rows must be visible")
        }
        for rowHeight in rowHeights.dropFirst() {
            XCTAssertEqual(
                rowHeight,
                expectedRowHeight,
                accuracy: 0.5,
                "Purchase request rows must have a consistent height"
            )
        }

        XCTAssertFalse(app.staticTexts["Needs a buyer"].exists)

        let firstNeedID = "10000000-0000-4000-8000-000000000001"
        let progressButton = app.buttons[
            "shared-plan-editor-need-progress-\(firstNeedID)"
        ]
        XCTAssertTrue(progressButton.waitForExistence(timeout: 3))
        progressButton.tap()

        XCTAssertTrue(app.navigationBars["Purchase progress"].waitForExistence(timeout: 3))
        let preview = app.descendants(matching: .any)[
            "shared-plan-editor-need-progress-preview-\(firstNeedID)"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertEqual(
            preview.value as? String,
            "Requested 2, assigned 0, bought 0"
        )
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Purchase progress"].waitForExistence(timeout: 2))

        let firstRowMenu = app.buttons["More actions for 新幹線チケット"]
        XCTAssertTrue(firstRowMenu.waitForExistence(timeout: 3))
        firstRowMenu.tap()
        let purchaseProgressAction = app.buttons["Purchase progress"].firstMatch
        XCTAssertTrue(purchaseProgressAction.waitForExistence(timeout: 3))
        purchaseProgressAction.tap()
        XCTAssertTrue(app.navigationBars["Purchase progress"].waitForExistence(timeout: 3))

        XCTAssertFalse(app.staticTexts["Wanted, assigned, and fulfilled quantities are saved as separate collaborative edits."].exists)
        takeScreenshot(named: "Shared-Plan-Purchase-Redesign")
    }

    @MainActor
    func testProductionInvitationSurfaceWhenExplicitlyRequired() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["COMINAVI_E2E_INVITATION_UI_REQUIRED"] == "1" else {
            return
        }

        let app = XCUIApplication()
        guard let rawInvitationURL = environment["COMINAVI_E2E_INVITATION_URL"],
              let invitationURL = URL(string: rawInvitationURL)
        else {
            return XCTFail("A valid invitation URL is required")
        }

        switch environment["COMINAVI_E2E_INVITATION_OPEN_MODE"] {
        case "cold":
            if app.state != .notRunning {
                app.terminate()
            }
            XCUIDevice.shared.system.open(invitationURL)
        case "warm":
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            app.open(invitationURL)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Open", "開く"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 2) {
                    button.tap()
                    break
                }
            }
        default:
            return XCTFail("A supported invitation open mode is required")
        }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let invitationTitle = app.navigationBars["共有プランへの招待"]
        XCTAssertTrue(invitationTitle.waitForExistence(timeout: 20))
        XCTAssertEqual(app.navigationBars.matching(
            NSPredicate(format: "identifier == %@", "共有プランへの招待")
        ).count, 1)

        let action = environment["COMINAVI_E2E_INVITATION_UI_ACTION"]
        if action == "expect-unavailable" {
            let error = app.staticTexts["shared-plan-invitation-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["このプランに参加"].exists)
            let cancel = app.buttons["キャンセル"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(invitationTitle.waitForNonExistence(timeout: 10))
            return
        }

        if let expectedPlanName = environment["COMINAVI_E2E_INVITATION_PLAN_NAME"] {
            let planName = app.staticTexts["shared-plan-invitation-plan-name"]
            XCTAssertTrue(planName.waitForExistence(timeout: 20))
            XCTAssertTrue(planName.label.contains(expectedPlanName))
        }
        let comiket = app.staticTexts["shared-plan-invitation-comiket"]
        XCTAssertTrue(comiket.waitForExistence(timeout: 5))
        XCTAssertTrue(comiket.label.contains("C108"))

        switch action {
        case "authenticate-google-accept":
            let login = app.buttons["ログインして続ける"]
            XCTAssertTrue(login.waitForExistence(timeout: 10))
            login.tap()

            let google = app.buttons.matching(
                NSPredicate(
                    format: "label IN %@",
                    ["Googleでログイン", "Sign in with Google"]
                )
            ).firstMatch
            XCTAssertTrue(google.waitForExistence(timeout: 15))
            google.tap()

            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let continueLabels = ["続ける", "Continue"]
            for label in continueLabels {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 2) {
                    button.tap()
                    break
                }
            }

            let accept = app.buttons["このプランに参加"]
            XCTAssertTrue(
                accept.waitForExistence(timeout: 90),
                "The preserved Google provider session did not return to invitation confirmation"
            )
            accept.tap()
            XCTAssertTrue(invitationTitle.waitForNonExistence(timeout: 30))
        case "accept":
            let accept = app.buttons["このプランに参加"]
            XCTAssertTrue(accept.waitForExistence(timeout: 10))
            accept.tap()
            XCTAssertTrue(invitationTitle.waitForNonExistence(timeout: 20))
        case "dismiss":
            let cancel = app.buttons["キャンセル"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(invitationTitle.waitForNonExistence(timeout: 10))
        default:
            XCTFail("A supported invitation UI action is required")
        }
    }

    @MainActor
    func testShinagakiLightboxDoubleTapZoomsAndResets() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-ui-testing-shinagaki-lightbox")
        app.launch()

        let zoomImage = app.descendants(matching: .any)["shinagaki-zoom-image"]
        XCTAssertTrue(zoomImage.waitForExistence(timeout: 5))
        let fittedZoomValue = try XCTUnwrap(zoomImage.value as? String)

        zoomImage
            .coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
            .doubleTap()
        expectation(
            for: NSPredicate(format: "value != %@", fittedZoomValue),
            evaluatedWith: zoomImage
        )
        waitForExpectations(timeout: 3)
        takeScreenshot(named: "Shinagaki-Double-Tap-Zoom")

        zoomImage.doubleTap()
        expectation(
            for: NSPredicate(format: "value == %@", fittedZoomValue),
            evaluatedWith: zoomImage
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testCatalogTabsExploreLayoutsAndGlobalDay() throws {
        let app = XCUIApplication()
        app.launch()

        let catalogTab = app.buttons["Catalog"]
        XCTAssertTrue(catalogTab.waitForExistence(timeout: 10))
        catalogTab.tap()

        let retryButton = app.buttons["Try Again"]
        if retryButton.waitForExistence(timeout: 2) {
            retryButton.tap()
        }

        let eventDayBanner = app.buttons["global-event-day-banner"]
        guard eventDayBanner.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "A downloaded authenticated catalog is required for this integration test.")
        }

        let mapTab = app.buttons["Map"].firstMatch
        let exploreTab = app.buttons["Explore"].firstMatch
        XCTAssertTrue(mapTab.exists)
        XCTAssertTrue(exploreTab.exists)
        XCTAssertLessThan(mapTab.frame.minX, exploreTab.frame.minX)

        exploreTab.tap()
        XCTAssertTrue(app.otherElements["explore-screen"].waitForExistence(timeout: 5))
        let gallery = app.collectionViews["explore-gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        XCTAssertEqual(
            gallery.value as? String,
            expectedInitialGalleryColumns(for: app)
        )

        gallery.pinch(withScale: 0.35, velocity: -1.5)
        expectation(
            for: NSPredicate(format: "value == %@", "5 columns"),
            evaluatedWith: gallery
        )
        waitForExpectations(timeout: 5)

        gallery.pinch(withScale: 2.7, velocity: 1.5)
        expectation(
            for: NSPredicate(format: "value == %@", "2 columns"),
            evaluatedWith: gallery
        )
        waitForExpectations(timeout: 5)

        app.buttons["explore-layout-button"].tap()
        XCTAssertTrue(app.scrollViews["explore-list"].waitForExistence(timeout: 5))

        app.buttons["explore-filter-button"].tap()
        XCTAssertTrue(app.otherElements["explore-filter-sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["explore-genre-picker"].exists)
        XCTAssertTrue(app.buttons["explore-tag-picker"].exists)
        XCTAssertTrue(app.buttons["explore-shinagaki-all"].exists)
        XCTAssertTrue(app.buttons["explore-attendance-all"].exists)
        XCTAssertTrue(app.buttons["explore-space-all"].exists)
        takeScreenshot(named: "Explore-Filters-Expanded")
        app.buttons["Done"].tap()

        eventDayBanner.tap()
        XCTAssertTrue(app.otherElements["catalog-event-day-sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["global-day-1"].exists)
        let secondDay = app.buttons["global-day-2"]
        XCTAssertTrue(secondDay.exists)
        secondDay.tap()
        XCTAssertEqual(secondDay.value as? String, "Selected")
        app.buttons["catalog-settings-done"].tap()

        mapTab.tap()
        XCTAssertTrue(eventDayBanner.waitForExistence(timeout: 5))
        XCTAssertTrue(eventDayBanner.label.contains("Day 2"))
    }

    @MainActor
    func testNoCatalogKeepsSharedPlansAndProfileAvailable() {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-ui-testing-no-catalog-shell")
        app.launch()

        let shell = app.otherElements["catalog-independent-shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["共有プラン"].exists)
        XCTAssertTrue(app.buttons["Profile"].exists)
        XCTAssertTrue(app.navigationBars["共有プラン"].exists)

        app.buttons["Catalog"].tap()
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))

        app.buttons["共有プラン"].tap()
        XCTAssertTrue(app.navigationBars["共有プラン"].waitForExistence(timeout: 5))
    }

    /// Opt-in production acceptance for a preserved signed-in device or
    /// simulator. This exercises discovery, authenticated artifact download,
    /// verification, installation, and the real C108 catalog shell.
    @MainActor
    func testLiveProductionC108CatalogDownloadsAndOpens() {
        let app = XCUIApplication()
        app.launch()

        let eventDayBanner = app.buttons["global-event-day-banner"]
        if !eventDayBanner.waitForExistence(timeout: 5) {
            let mapTab = app.buttons["Map"].firstMatch
            if mapTab.waitForExistence(timeout: 10), mapTab.isHittable {
                mapTab.tap()
            } else {
                let catalogTab = app.buttons["Catalog"].firstMatch
                XCTAssertTrue(catalogTab.waitForExistence(timeout: 10))
                XCTAssertTrue(catalogTab.isHittable)
                catalogTab.tap()
            }
        }

        let retryButton = app.buttons["Try Again"]
        if retryButton.waitForExistence(timeout: 2) {
            retryButton.tap()
        }

        XCTAssertTrue(
            eventDayBanner.waitForExistence(timeout: 180),
            "The authenticated production C108 catalog did not finish installing"
        )
        XCTAssertTrue(
            eventDayBanner.label.contains("108"),
            "The installed production catalog is not C108: \(eventDayBanner.label)"
        )

        eventDayBanner.tap()
        XCTAssertTrue(
            app.otherElements["catalog-event-day-sheet"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["global-day-1"].exists)
        XCTAssertTrue(app.buttons["global-day-2"].exists)
        takeScreenshot(named: "Live-C108-Catalog-Ready")
    }

    /// Opt-in production acceptance for a preserved signed-in physical device.
    /// The stable prefix names only agent-created test data; no account or
    /// invitation capability is embedded in source. Devices without it skip.
    @MainActor
    func testLiveSharedPlanRebootstrapReachesSynchronizedState() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("The live Shared Plan acceptance runs only on a physical device")
        #else
            let planNamePrefix = "[E2E] Shared Plans Acceptance"

            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()

            let plansTab = app.buttons["Shared Plans"].exists
                ? app.buttons["Shared Plans"]
                : app.buttons["共有プラン"]
            XCTAssertTrue(plansTab.waitForExistence(timeout: 15))
            plansTab.tap()

            let plan = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", planNamePrefix)
            ).firstMatch
            guard plan.waitForExistence(timeout: 15) else {
                throw XCTSkip("No preserved live Shared Plan test fixture is installed")
            }
            plan.tap()

            let openEditor = app.buttons["shared-plan-open-editor"]
            XCTAssertTrue(openEditor.waitForExistence(timeout: 10))
            openEditor.tap()

            let recovery = app.descendants(matching: .any)[
                "shared-plan-editor-recovery"
            ]
            let discard = app.buttons["shared-plan-editor-recovery-discard"]
            if discard.waitForExistence(timeout: 3) {
                discard.tap()
                let confirm = app.buttons[
                    "shared-plan-editor-recovery-discard-confirmation"
                ]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.tap()
            }

            let syncStatus = app.descendants(matching: .any)[
                "shared-plan-editor-sync-status"
            ]
            XCTAssertTrue(syncStatus.waitForExistence(timeout: 10))
            expectation(
                for: NSPredicate(format: "label CONTAINS[c] %@", "up to date"),
                evaluatedWith: syncStatus
            )
            waitForExpectations(timeout: 30)
            XCTAssertFalse(recovery.exists)

            // A framing regression can briefly clear recovery while reconnecting
            // and then quarantine again. Keep the editor alive for another cycle.
            expectation(
                for: NSPredicate(format: "exists == false"),
                evaluatedWith: recovery
            )
            waitForExpectations(timeout: 5)
            XCTAssertFalse(recovery.exists)
            takeScreenshot(named: "Live-Shared-Plan-Synchronized")
        #endif
    }

    @MainActor
    func testExploreEventDaySelectorStaysAtTopLeading() {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let eventDaySelector = app.buttons["global-event-day-banner"]
        XCTAssertTrue(eventDaySelector.waitForExistence(timeout: 20))

        app.buttons["Explore"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["explore-screen"].waitForExistence(timeout: 5))

        let filterButton = app.buttons["explore-filter-button"]
        XCTAssertTrue(filterButton.exists)
        XCTAssertLessThan(eventDaySelector.frame.midX, app.frame.midX)
        XCTAssertLessThan(eventDaySelector.frame.maxX, filterButton.frame.minX)
        takeScreenshot(named: "Explore-Selector-Top-Leading")
    }

    @MainActor
    func testDemoIPadMapSelectorAndActionsUseLeadingLayout() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        guard app.frame.width >= 700 else {
            throw XCTSkip("This adaptive layout assertion requires an iPad-width window.")
        }

        let eventDaySelector = app.buttons["global-event-day-banner"]
        let whereAmI = app.buttons["where-am-i-button"]
        let findTable = app.buttons["find-table-button"]
        XCTAssertTrue(eventDaySelector.waitForExistence(timeout: 20))
        XCTAssertTrue(whereAmI.waitForExistence(timeout: 20))
        XCTAssertTrue(findTable.waitForExistence(timeout: 20))

        XCTAssertLessThan(eventDaySelector.frame.midX, app.frame.midX)
        XCTAssertEqual(whereAmI.frame.midY, findTable.frame.midY, accuracy: 2)
        XCTAssertLessThan(whereAmI.frame.maxX, findTable.frame.minX)
        takeScreenshot(named: "Map-iPad-Leading-Controls")
    }

    @MainActor
    func testDemoExploreExpandedFiltersScrollAndFit() {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        XCTAssertTrue(app.buttons["global-event-day-banner"].waitForExistence(timeout: 20))
        app.buttons["Explore"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["explore-screen"].waitForExistence(timeout: 5))
        app.buttons["explore-filter-button"].tap()
        XCTAssertTrue(app.otherElements["explore-filter-sheet"].waitForExistence(timeout: 5))

        for identifier in [
            "explore-genre-picker",
            "explore-tag-picker",
            "explore-shinagaki-all",
            "explore-attendance-all",
            "explore-space-all",
        ] {
            XCTAssertTrue(app.buttons[identifier].exists, "Missing expanded filter \(identifier)")
        }

        let filterSheet = app.otherElements["explore-filter-sheet"]
        let savedFilter = app.buttons["explore-saved-all"]
        for _ in 0 ..< 4 {
            if savedFilter.exists { break }
            filterSheet.swipeUp()
        }
        XCTAssertTrue(savedFilter.exists)

        let lastFavoriteColor = app.buttons["explore-favorite-color-9"]
        for _ in 0 ..< 4 {
            if lastFavoriteColor.isHittable { break }
            filterSheet.swipeUp()
        }
        XCTAssertTrue(lastFavoriteColor.isHittable)
        lastFavoriteColor.tap()
        XCTAssertEqual(lastFavoriteColor.value as? String, "Selected")

        XCTAssertTrue(app.buttons["Done"].isHittable)
        takeScreenshot(named: "Explore-Filters-Expanded")
    }

    @MainActor
    func testDemoProfileProvidesItsNavigationContext() {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let profileTab = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profileTab.waitForExistence(timeout: 20))
        profileTab.tap()

        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        let followingImport = app.descendants(matching: .any)["profile-following-import"]
        XCTAssertTrue(
            followingImport.exists,
            "Profile destinations should remain discoverable inside a navigation container."
        )
        XCTAssertTrue(
            followingImport.isEnabled,
            "The import destination must remain open so authentication errors can provide recovery."
        )
        followingImport.tap()
        XCTAssertTrue(app.navigationBars["X followed circles"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackgroundingAndReturningToLogin() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-ui-testing-show-sign-in")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        XCUIDevice.shared.press(.home)
        let enteredBackground =
            app.wait(for: .runningBackground, timeout: 2)
            || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(enteredBackground)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.buttons["Login via circle.ms"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testJapaneseLocalizationLaunchesWithLocalizedSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-cominavi-ui-testing-show-sign-in",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["コミナビへようこそ！"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["circle.msでログイン"].exists)
        XCTAssertFalse(app.buttons["C104のデモデータを見る"].exists)
    }

    @MainActor
    func testJapaneseToolboxShowsOfficialResourcesAndPersistentChecklist() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-cominavi-demo-data",
        ]
        app.launch()

        let toolboxTab = app.buttons["お役立ち"].firstMatch
        XCTAssertTrue(toolboxTab.waitForExistence(timeout: 20))
        toolboxTab.tap()

        XCTAssertTrue(app.navigationBars["お役立ち"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["C108の重要情報"].exists)

        let copyVenueButton = app.buttons["toolbox-copy-venue"]
        for _ in 0..<6 where !copyVenueButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(copyVenueButton.exists)

        let comiketXResource =
            app.descendants(matching: .any)["toolbox-resource-comiket-x"]
        for _ in 0..<6 where !comiketXResource.exists {
            app.swipeUp()
        }
        XCTAssertTrue(comiketXResource.exists)

        let admissionItem = app.buttons["toolbox-checklist-admission"]
        for _ in 0..<6 where !admissionItem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(admissionItem.isHittable)
        let initialValue = try XCTUnwrap(admissionItem.value as? String)
        admissionItem.tap()
        expectation(
            for: NSPredicate(format: "value != %@", initialValue),
            evaluatedWith: admissionItem
        )
        waitForExpectations(timeout: 3)
        let toggledValue = try XCTUnwrap(admissionItem.value as? String)

        app.buttons["地図"].firstMatch.tap()
        toolboxTab.tap()
        let reopenedAdmissionItem = app.buttons["toolbox-checklist-admission"]
        for _ in 0..<6 where !reopenedAdmissionItem.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reopenedAdmissionItem.isHittable)
        expectation(
            for: NSPredicate(format: "value == %@", toggledValue),
            evaluatedWith: reopenedAdmissionItem
        )
        waitForExpectations(timeout: 3)

        takeScreenshot(named: "Toolbox-Japanese")
    }

    @MainActor
    func testJapaneseToolboxShowsLocalEventReminderChoices() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-cominavi-demo-data",
        ]
        app.launch()

        let toolboxTab = app.buttons["お役立ち"].firstMatch
        XCTAssertTrue(toolboxTab.waitForExistence(timeout: 20))
        toolboxTab.tap()

        XCTAssertTrue(app.staticTexts["C108当日リマインダー"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["toolbox-reminder-early-entry"].exists)
        XCTAssertTrue(app.switches["toolbox-reminder-am-entry"].exists)
        XCTAssertTrue(app.staticTexts["10:30"].exists)
        XCTAssertTrue(app.staticTexts["11:00"].exists)

        takeScreenshot(named: "C108-Event-Reminders-iPad")
    }

    @MainActor
    func testSignInDoesNotOfferDemoDataOrSourceControls() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-ui-testing-show-sign-in")
        app.launch()

        XCTAssertTrue(app.buttons["Login via circle.ms"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sign-in-demo-data"].exists)
        XCTAssertFalse(app.otherElements["sign-in-circlems-environment"].exists)
    }

    @MainActor
    func testDemoMapDatabaseSurvivesBackgroundAndReconnect() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        XCTAssertTrue(app.otherElements["campus-map-canvas"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Map unavailable"].exists)

        XCUIDevice.shared.press(.home)
        let enteredBackground =
            app.wait(for: .runningBackground, timeout: 2)
            || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(enteredBackground)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.otherElements["campus-map-canvas"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Map unavailable"].exists)
    }

    @MainActor
    func testDemoMapRemainsVisibleAcrossDaySwitches() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        let eventDayBanner = app.buttons["global-event-day-banner"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        XCTAssertTrue(eventDayBanner.waitForExistence(timeout: 5))

        for day in [2, 1] {
            eventDayBanner.tap()
            let dayButton = app.buttons["global-day-\(day)"]
            XCTAssertTrue(dayButton.waitForExistence(timeout: 5))
            dayButton.tap()

            XCTAssertTrue(map.exists, "The map surface disappeared while switching to day \(day)")
            XCTAssertEqual(dayButton.value as? String, "Selected")
            takeScreenshot(named: "C104-Day-\(day)-Map-Transition")

            app.buttons["catalog-settings-done"].tap()
            takeScreenshot(named: "C104-Day-\(day)-Map-Visible")
            XCTAssertTrue(map.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Map unavailable"].exists)
        }
    }

    @MainActor
    func testDemoCampusLongPressSetsCurrentLocation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))

        map.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.50))
            .press(forDuration: 0.7)

        XCTAssertTrue(
            app.descendants(matching: .any)["current-location-sheet"]
                .waitForExistence(timeout: 8),
            "Long-pressing East 1–3 from campus should set and present the current location"
        )
        takeScreenshot(named: "Current-Location-Visible-Viewport-Center")
    }

    @MainActor
    func testDemoExploreGalleryPinchZoomPinsItsOrigin() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let exploreTab = app.buttons["Explore"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 30))
        exploreTab.tap()

        let gallery = app.collectionViews["explore-gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        XCTAssertEqual(
            gallery.value as? String,
            expectedInitialGalleryColumns(for: app)
        )
        for _ in 0..<4 {
            gallery.swipeUp(velocity: .fast)
        }

        let gestureOrigin = CGPoint(x: gallery.frame.midX, y: gallery.frame.midY)
        let visibleCells = gallery.cells.allElementsBoundByIndex.filter {
            $0.frame.intersects(gallery.frame) && !$0.identifier.isEmpty
        }
        let anchoredCell = try XCTUnwrap(
            visibleCells.first { $0.frame.contains(gestureOrigin) }
                ?? visibleCells.min {
                    let lhsDistance = distance(from: gestureOrigin, to: $0.frame)
                    let rhsDistance = distance(from: gestureOrigin, to: $1.frame)
                    if abs(lhsDistance - rhsDistance) < 0.5 {
                        return $0.frame.minX < $1.frame.minX
                    }
                    return lhsDistance < rhsDistance
                }
        )
        let anchoredIdentifier = anchoredCell.identifier
        let anchoredFrame = anchoredCell.frame

        gallery.pinch(withScale: 0.35, velocity: -1.5)
        expectation(
            for: NSPredicate(format: "value == %@", "5 columns"),
            evaluatedWith: gallery
        )
        waitForExpectations(timeout: 5)

        let zoomedAnchor = gallery.cells[anchoredIdentifier]
        XCTAssertTrue(zoomedAnchor.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            distance(from: gestureOrigin, to: zoomedAnchor.frame),
            8,
            "The circle under the pinch origin moved away while the gallery zoomed; "
                + "id=\(anchoredIdentifier), "
                + "origin=\(gestureOrigin), before=\(anchoredFrame), after=\(zoomedAnchor.frame)"
        )
        takeScreenshot(named: "Explore-Gallery-Anchored-Pinch-Zoom")

        gallery.pinch(withScale: 2.7, velocity: 1.5)
        expectation(
            for: NSPredicate(format: "value == %@", "2 columns"),
            evaluatedWith: gallery
        )
        waitForExpectations(timeout: 5)

        let restoredAnchor = gallery.cells[anchoredIdentifier]
        XCTAssertTrue(restoredAnchor.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            distance(from: gestureOrigin, to: restoredAnchor.frame),
            8,
            "The circle under the pinch origin moved away while the gallery zoomed back in"
        )
    }

    @MainActor
    func testDemoExplorePopularTagsSupportMultipleSelection() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let exploreTab = app.buttons["Explore"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 30))
        exploreTab.tap()

        let filterButton = app.buttons["explore-filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))

        let cloud = app.otherElements["explore-discovery-cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 20))
        let eventDayBanner = app.buttons["global-event-day-banner"]
        let searchField = app.textFields["explore-search-field"]
        XCTAssertTrue(eventDayBanner.exists)
        XCTAssertTrue(searchField.exists)

        let terms = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "explore-discovery-term-")
        )
        let firstTerm = terms.element(boundBy: 0)
        let secondTerm = terms.element(boundBy: 1)
        XCTAssertTrue(firstTerm.waitForExistence(timeout: 20))
        XCTAssertTrue(secondTerm.exists)

        firstTerm.tap()
        secondTerm.tap()

        XCTAssertTrue(app.buttons["explore-discovery-match-mode"].waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "value == %@", "2 active"),
            evaluatedWith: app.buttons["explore-filter-button"]
        )
        waitForExpectations(timeout: 5)
        let gallery = app.collectionViews["explore-gallery"]
        XCTAssertEqual(
            firstTerm.frame.minX,
            gallery.frame.minX + 16,
            accuracy: 2,
            "The gallery header should align its discovery content with the circle-card inset."
        )
        XCTAssertEqual(gallery.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        eventDayBanner.swipeUp()
        expectation(
            for: NSPredicate(format: "hittable == false"),
            evaluatedWith: cloud
        )
        waitForExpectations(timeout: 5)
        XCTAssertFalse(eventDayBanner.isHittable)
        XCTAssertFalse(searchField.isHittable)

        gallery.swipeDown(velocity: .fast)
        expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: eventDayBanner
        )
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["explore-filter-button"].firstMatch.isHittable)

        app.buttons["explore-layout-button"].firstMatch.tap()
        let list = app.scrollViews["explore-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertEqual(list.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        XCTAssertTrue(eventDayBanner.isHittable)
        XCTAssertTrue(searchField.isHittable)
        eventDayBanner.swipeUp()
        XCTAssertFalse(eventDayBanner.isHittable)
        XCTAssertFalse(searchField.isHittable)
        takeScreenshot(named: "Explore-Discovery-Cloud-Multiple-Interests")
    }

    @MainActor
    func testDemoExploreAdaptsGalleryDensityAcrossRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let exploreTab = app.buttons["Explore"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 30))
        exploreTab.tap()

        let gallery = app.collectionViews["explore-gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        XCTAssertEqual(
            gallery.value as? String,
            expectedInitialGalleryColumns(for: app)
        )

        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(
            for: NSPredicate(
                format: "value == %@",
                expectedInitialGalleryColumns(forWidth: max(app.frame.width, app.frame.height))
            ),
            evaluatedWith: gallery
        )
        waitForExpectations(timeout: 8)

        XCTAssertTrue(app.buttons["global-event-day-banner"].isHittable)
        XCTAssertTrue(app.buttons["explore-filter-button"].isHittable)
        takeScreenshot(named: "Explore-iPad-Landscape-Adaptive")
    }

    @MainActor
    func testDemoExploreDiscoveryLoadingUsesStableChipLayout() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let exploreTab = app.buttons["Explore"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 30))
        exploreTab.tap()

        let cloud = app.otherElements["explore-discovery-cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 20))

        let loading = app.otherElements["explore-discovery-loading"]
        if loading.exists {
            XCTAssertEqual(
                cloud.descendants(matching: .progressIndicator).count,
                0
            )
            XCTAssertEqual(loading.frame.height, 96, accuracy: 1)
        }

        takeScreenshot(named: "Explore-Discovery-Loading")
    }

    @MainActor
    func testC104DemoMapSupportsSearchZoomAndSelection() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["global-event-day-banner"].exists)
        XCTAssertTrue(app.buttons["map-venue-selector"].exists)
        selectEast123(in: app)

        app.buttons["map-search-button"].tap()
        let searchField = app.textFields["map-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.typeText("PALE LIGHT")
        let searchSummary = app.staticTexts["map-search-summary"]
        XCTAssertTrue(searchSummary.waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "label != %@", "0 matching circles"),
            evaluatedWith: searchSummary
        )
        waitForExpectations(timeout: 15)

        app.buttons["map-genre-button"].tap()
        XCTAssertEqual(app.buttons["map-genre-button"].label, "Hide genre overlay")
        XCTAssertTrue(app.buttons["map-legend-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["map-legend-items"].waitForExistence(timeout: 30))
        app.buttons["map-search-button"].tap()
        let legendToggle = app.buttons["map-legend-toggle"]
        legendToggle.tap()
        XCTAssertFalse(app.scrollViews["map-legend-items"].waitForExistence(timeout: 1))

        map.pinch(withScale: 5, velocity: 2)
        let tableOffsets = [
            CGVector(dx: 0.25, dy: 0.52),
            CGVector(dx: 0.35, dy: 0.58),
            CGVector(dx: 0.75, dy: 0.52),
            CGVector(dx: 0.65, dy: 0.58),
        ]
        for offset in tableOffsets where !app.staticTexts["Circle details"].exists {
            map.coordinate(withNormalizedOffset: offset).tap()
            _ = app.staticTexts["Circle details"].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.staticTexts["Circle details"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.buttons["map-bookmark-button"].exists)
        XCTAssertTrue(app.buttons["map-circle-artwork-a"].waitForExistence(timeout: 3))
        app.buttons["map-circle-sheet-close"].tap()

        // C104 uses the real campus-to-table scale ratio; reaching circle-cut
        // detail requires substantially more zoom than the old tiny fixture.
        for _ in 0..<2 {
            map.pinch(withScale: 5, velocity: 2)
        }
        let artworkLoaded = NSPredicate(
            format: "value MATCHES %@",
            ".*[1-9][0-9]* circle images.*"
        )
        expectation(for: artworkLoaded, evaluatedWith: map)
        waitForExpectations(timeout: 15)
    }

    @MainActor
    func testDemoMapCircleSearchUsesStructuredTableLocation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        XCTAssertTrue(app.otherElements["unified-map-canvas"].waitForExistence(timeout: 30))
        selectEast123(in: app)

        app.buttons["map-search-button"].tap()
        let textSearchField = app.textFields["map-search-field"]
        XCTAssertTrue(textSearchField.waitForExistence(timeout: 3))
        let locationSearch = app.buttons["map-location-search-button"]
        XCTAssertTrue(locationSearch.exists)
        locationSearch.tap()

        let day = app.buttons["find-circle-day-1"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        makeHittable(day, in: app)
        day.tap()

        let venue = app.buttons["find-circle-venue-1"]
        XCTAssertTrue(venue.waitForExistence(timeout: 10))
        makeHittable(venue, in: app)
        venue.tap()

        let character = app.buttons["find-circle-character-シ"]
        XCTAssertTrue(character.waitForExistence(timeout: 5))
        makeHittable(character, in: app)
        character.tap()

        let digit = app.buttons["find-circle-digit-1"]
        XCTAssertTrue(digit.waitForExistence(timeout: 5))
        makeHittable(digit, in: app)
        digit.tap()

        let showCircle = app.buttons["find-circle-show"]
        XCTAssertTrue(showCircle.isEnabled)
        showCircle.tap()

        XCTAssertTrue(app.staticTexts["Circle details"].waitForExistence(timeout: 10))
        let address = app.buttons["map-circle-address-copy"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertTrue(address.label.contains("シ01"))
    }

    @MainActor
    func testDemoMapLayerMenuOffersBehaviorBasedViews() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        XCTAssertTrue(app.otherElements["unified-map-canvas"].waitForExistence(timeout: 30))
        let layerButton = app.buttons["map-layer-button"]
        XCTAssertTrue(layerButton.waitForExistence(timeout: 5))
        XCTAssertEqual(layerButton.value as? String, "6 of 6 shown")

        layerButton.tap()
        let beforeArrival = app.buttons["Before arrival"]
        XCTAssertTrue(beforeArrival.waitForExistence(timeout: 5))
        beforeArrival.tap()
        XCTAssertEqual(layerButton.value as? String, "3 of 6 shown")
        takeScreenshot(named: "Map-Layers-Before-Arrival")

        layerButton.tap()
        let onSite = app.buttons["On-site"]
        XCTAssertTrue(onSite.waitForExistence(timeout: 5))
        onSite.tap()
        XCTAssertEqual(layerButton.value as? String, "4 of 6 shown")
        takeScreenshot(named: "Map-Layers-On-Site")

        layerButton.tap()
        app.buttons["Arrival"].tap()
        XCTAssertEqual(layerButton.value as? String, "4 of 6 shown")
        takeScreenshot(named: "Map-Layers-Arrival")

        layerButton.tap()
        app.buttons["Hide Optional Layers"].tap()
        XCTAssertEqual(layerButton.value as? String, "0 of 6 shown")
    }

    @MainActor
    func testDemoEastHallServicesRemainVisibleAtDetailedZoom() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        selectEast123(in: app)

        let layerButton = app.buttons["map-layer-button"]
        XCTAssertTrue(layerButton.waitForExistence(timeout: 5))
        layerButton.tap()
        app.buttons["On-site"].tap()

        map.pinch(withScale: 4.5, velocity: 2)
        takeScreenshot(named: "East-1-Services-Detailed-Zoom")

        XCTAssertTrue(map.exists)
        XCTAssertFalse(app.staticTexts["Map unavailable"].exists)
    }

    @MainActor
    func testC104DemoGenreOverlayLoadsAtVenueScale() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launchArguments.append("-cominavi-ui-testing-rotated-camera")
        app.launch()

        XCTAssertTrue(app.otherElements["unified-map-canvas"].waitForExistence(timeout: 30))
        selectEast123(in: app)

        let genreButton = app.buttons["map-genre-button"]
        XCTAssertTrue(genreButton.waitForExistence(timeout: 5))
        genreButton.tap()

        XCTAssertEqual(genreButton.label, "Hide genre overlay")
        let legendToggle = app.buttons["map-legend-toggle"]
        let legendItems = app.scrollViews["map-legend-items"]
        let compass = app.buttons["map-compass-button"]
        XCTAssertTrue(legendToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(legendItems.waitForExistence(timeout: 30))
        XCTAssertTrue(compass.waitForExistence(timeout: 5))
        XCTAssertEqual(legendToggle.frame.maxX, compass.frame.maxX, accuracy: 1)
        XCTAssertEqual(legendItems.frame.maxX, compass.frame.maxX, accuracy: 1)
        takeScreenshot(named: "C104-Genre-Overlay-Venue-Scale")
    }

    @MainActor
    func testC104DemoMapCameraCommitsPanAndZoom() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        selectEast123(in: app)
        let compass = app.buttons["map-compass-button"]
        XCTAssertTrue(compass.waitForExistence(timeout: 3))
        XCTAssertFalse((map.value as? String)?.contains("bearing 0.0 degrees") == true)
        compass.tap()
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "bearing 0.0 degrees"),
            evaluatedWith: map
        )
        waitForExpectations(timeout: 3)

        let initialValue = try XCTUnwrap(map.value as? String)
        XCTAssertTrue(initialValue.contains("camera offset"))

        map.pinch(withScale: 2.5, velocity: 1.5)
        expectation(
            for: NSPredicate(format: "value != %@", initialValue),
            evaluatedWith: map
        )
        waitForExpectations(timeout: 5)
        let zoomedValue = try XCTUnwrap(map.value as? String)

        let dragStart = map.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.62))
        let dragEnd = map.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.38))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        expectation(
            for: NSPredicate(format: "value != %@", zoomedValue),
            evaluatedWith: map
        )
        waitForExpectations(timeout: 5)

        let pannedValue = try XCTUnwrap(map.value as? String)
        XCTAssertNotEqual(pannedValue, zoomedValue)
        XCTAssertTrue(pannedValue.contains("bearing"))
        takeScreenshot(named: "Map-Camera-Pan-Zoom")
    }

    @MainActor
    func testComiNaviMapIconsRenderAtFacilityScale() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        selectEast123(in: app)

        let initialValue = try XCTUnwrap(map.value as? String)
        map.pinch(withScale: 4, velocity: 1.5)
        expectation(
            for: NSPredicate(format: "value != %@", initialValue),
            evaluatedWith: map
        )
        waitForExpectations(timeout: 5)

        XCTAssertFalse(app.staticTexts["Map unavailable"].exists)
        takeScreenshot(named: "ComiNavi-Map-Icons-Facility-Scale")
    }

    @MainActor
    func testC104DemoCampusLoadsAndDrillsIntoVenue() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        let campus = app.otherElements["campus-map-canvas"]
        XCTAssertTrue(campus.waitForExistence(timeout: 30))
        let unifiedMap = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(unifiedMap.waitForExistence(timeout: 5))
        XCTAssertTrue((campus.value as? String)?.contains("4 venues") == true)
        XCTAssertFalse(app.buttons["map-legend-toggle"].exists)
        let attribution = app.buttons["map-data-attribution-button"]
        XCTAssertTrue(attribution.exists)
        XCTAssertTrue((attribution.value as? String)?.contains("OpenStreetMap US") == true)
        takeScreenshot(named: "C104-Campus-Corridors")

        let initialCameraValue = campus.value as? String
        campus.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(campus.value as? String, initialCameraValue)

        let zoomedCameraValue = campus.value as? String
        campus.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
            .press(
                forDuration: 0.05,
                thenDragTo: campus.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
            )
        XCTAssertNotEqual(campus.value as? String, zoomedCameraValue)
        XCTAssertTrue(app.buttons["map-venue-selector"].label.contains("Campus"))

        selectEast123(in: app)
        XCTAssertTrue(unifiedMap.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["map-venue-selector"].label.contains("東123"))
        app.buttons["map-genre-button"].tap()
        let legendToggle = app.buttons["map-legend-toggle"]
        XCTAssertTrue(legendToggle.waitForExistence(timeout: 5))
        let legendItems = app.scrollViews["map-legend-items"]
        XCTAssertTrue(legendItems.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Genre overlay"].exists)
        takeScreenshot(named: "C104-Authored-Area-Labels")
    }

    @MainActor
    func testC104DemoEast456UsesAuthoredImageRotation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launch()

        XCTAssertTrue(app.otherElements["campus-map-canvas"].waitForExistence(timeout: 30))
        let selector = app.buttons["map-venue-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        let east456 = app.buttons["東456"]
        XCTAssertTrue(east456.waitForExistence(timeout: 3))
        east456.tap()
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "東456"),
            evaluatedWith: selector
        )
        waitForExpectations(timeout: 5)

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertTrue((map.value as? String)?.contains("bearing") == true)
        takeScreenshot(named: "C104-East456-Image-Orientation")
    }

    @MainActor
    func testWhereAmIPlacesAHeadingAwareUserMarker() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-demo-data")
        app.launchArguments.append("-cominavi-ui-testing-where-am-i")
        app.launch()

        let entryButton = app.buttons["where-am-i-button"]
        XCTAssertTrue(entryButton.waitForExistence(timeout: 30))
        entryButton.tap()

        let eastVenue = app.buttons["where-am-i-venue-1"]
        XCTAssertTrue(eastVenue.waitForExistence(timeout: 5))
        makeHittable(eastVenue, in: app)
        takeScreenshot(named: "WhereAmI-Venue")
        eastVenue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let characterSearchButton = app.buttons["where-am-i-character-search-button"]
        XCTAssertTrue(characterSearchButton.waitForExistence(timeout: 3))
        characterSearchButton.tap()
        let characterSearchField = app.textFields["where-am-i-character-search-field"]
        XCTAssertTrue(characterSearchField.waitForExistence(timeout: 3))
        characterSearchField.typeText("shi")

        let character = app.buttons["where-am-i-character-シ"]
        XCTAssertTrue(character.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["where-am-i-character-ア"].exists)
        makeHittable(character, in: app)
        takeScreenshot(named: "WhereAmI-Character")
        character.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let digitNine = app.buttons["where-am-i-digit-9"]
        makeHittable(digitNine, in: app)
        digitNine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        digitNine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["where-am-i-number-error"].waitForExistence(timeout: 2))
        takeScreenshot(named: "WhereAmI-Number-OutOfBounds")
        app.buttons["where-am-i-clear"].tap()

        let digitOne = app.buttons["where-am-i-digit-1"]
        makeHittable(digitOne, in: app)
        digitOne.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let locate = app.buttons["where-am-i-locate"]
        XCTAssertTrue(locate.isEnabled)
        takeScreenshot(named: "WhereAmI-Number")
        locate.tap()

        let spaceCode = app.staticTexts["current-location-space-code"]
        XCTAssertTrue(spaceCode.waitForExistence(timeout: 5))
        XCTAssertEqual(spaceCode.label, "シ01")
        XCTAssertTrue(app.buttons["current-location-update"].exists)
        XCTAssertFalse(app.buttons["current-location-share"].exists)
        takeScreenshot(named: "WhereAmI-Located")
        app.buttons["current-location-copy"].tap()
        XCTAssertEqual(app.buttons["current-location-copy"].label, "Copied")
        let done = app.buttons["Done"]
        done.tap()
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: done
        )
        waitForExpectations(timeout: 3)

        let map = app.otherElements["unified-map-canvas"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let userPositioned = NSPredicate(format: "value CONTAINS %@", "user location シ01")
        expectation(for: userPositioned, evaluatedWith: map)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["current-location-button"].exists)
        XCTAssertTrue(app.buttons["banner-update-location"].exists)
        takeScreenshot(named: "WhereAmI-Map-Focused")

        let destinationEntry = app.buttons["find-table-button"]
        XCTAssertTrue(destinationEntry.waitForExistence(timeout: 5))
        destinationEntry.tap()

        let destinationVenue = app.buttons["find-table-venue-1"]
        XCTAssertTrue(destinationVenue.waitForExistence(timeout: 5))
        makeHittable(destinationVenue, in: app)
        destinationVenue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let destinationCharacter = app.buttons["find-table-character-ア"]
        makeHittable(destinationCharacter, in: app)
        destinationCharacter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let destinationNumber = app.buttons["find-table-digit-2"]
        makeHittable(destinationNumber, in: app)
        destinationNumber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let showOnMap = app.buttons["find-table-show"]
        XCTAssertTrue(showOnMap.isEnabled)
        showOnMap.tap()

        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "ア02"),
            evaluatedWith: destinationEntry
        )
        waitForExpectations(timeout: 5)
        let destinationOnMap = NSPredicate(format: "value CONTAINS %@", "destination ア02")
        expectation(for: destinationOnMap, evaluatedWith: map)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["clear-destination-button"].exists)
        XCTAssertTrue(app.buttons["copy-destination-button"].exists)
        takeScreenshot(named: "FindTable-Pinned")
    }

    @MainActor
    func testAuthenticatedCatalogSearchBuildsDerivedIndex() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-circlems-data")
        app.launchArguments.append("-cominavi-ui-testing-map-index-probe")
        app.launch()

        let searchButton = app.buttons["map-search-button"]
        guard searchButton.waitForExistence(timeout: 12) else {
            throw XCTSkip("A saved Circle.ms login and downloaded catalog are required.")
        }

        searchButton.tap()
        let searchField = app.textFields["map-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        // C108's testing catalog contains compatibility placeholders such as
        // "1日目東ア01a" rather than production circle names.
        searchField.typeText("1日目")

        let summary = app.staticTexts["map-search-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        XCTAssertNotEqual(summary.label, "0 matching circles")
    }

    @MainActor
    func testAuthenticatedCatalogPickerDiscoversAndSwitchesEvents() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-cominavi-circlems-data")
        app.launch()

        let selector = app.buttons["global-event-day-banner"]
        guard selector.waitForExistence(timeout: 20) else {
            throw XCTSkip("A saved Circle.ms login and downloaded catalog are required.")
        }

        selector.tap()
        XCTAssertTrue(app.otherElements["catalog-event-day-sheet"].waitForExistence(timeout: 3))
        app.buttons["catalog-event-selection-link"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["catalog-event-selection-page"]
                .waitForExistence(timeout: 3)
        )
        let newestEvent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Comic Market 108")
        ).firstMatch
        let oldestEvent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Comic Market 100")
        ).firstMatch
        XCTAssertTrue(newestEvent.exists)
        XCTAssertTrue(oldestEvent.exists)

        let originalCatalogLabel = selector.label
        let alternateEventName =
            originalCatalogLabel.contains("108")
            ? "Comic Market 104"
            : "Comic Market 108"
        let alternateEvent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", alternateEventName)
        ).firstMatch
        XCTAssertTrue(alternateEvent.exists)
        alternateEvent.tap()

        expectation(
            for: NSPredicate(format: "value == %@", "Selected"),
            evaluatedWith: alternateEvent
        )
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.buttons["global-day-1"].waitForExistence(timeout: 30))
        app.buttons["catalog-settings-done"].tap()
        XCTAssertTrue(
            selector.label.contains(
                alternateEventName.replacingOccurrences(of: "Comic Market ", with: "C")))

        // Leave the user's simulator on the newest currently supported catalog.
        if alternateEventName != "Comic Market 108" {
            selector.tap()
            app.buttons["catalog-event-selection-link"].tap()
            let event108 = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Comic Market 108")
            ).firstMatch
            XCTAssertTrue(event108.waitForExistence(timeout: 3))
            event108.tap()
            expectation(
                for: NSPredicate(format: "value == %@", "Selected"),
                evaluatedWith: event108
            )
            waitForExpectations(timeout: 30)
            app.buttons["catalog-settings-done"].tap()
            XCTAssertTrue(selector.label.contains("C108"))
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    @MainActor
    private func takeScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func expectedInitialGalleryColumns(for app: XCUIApplication) -> String {
        expectedInitialGalleryColumns(forWidth: app.frame.width)
    }

    private func expectedInitialGalleryColumns(forWidth width: CGFloat) -> String {
        let columns: Int
        if width >= 1_100 {
            columns = 4
        } else if width >= 700 {
            columns = 3
        } else {
            columns = 2
        }
        return "\(columns) columns"
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }

    @MainActor
    private func selectEast123(in app: XCUIApplication) {
        let selector = app.buttons["map-venue-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        let east123 = app.buttons["東123"]
        XCTAssertTrue(east123.waitForExistence(timeout: 3))
        east123.tap()
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "東123"),
            evaluatedWith: selector
        )
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 100)
        for _ in 0..<12 {
            if element.exists {
                let frame = element.frame
                if element.isHittable, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    return
                }
            }
            app.swipeUp()
        }
        let frame = element.frame
        XCTAssertTrue(
            element.isHittable && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        )
    }
}
