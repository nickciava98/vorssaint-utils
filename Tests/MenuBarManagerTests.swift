// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

enum MenuBarManagerTests {
    static func run(_ suite: TestSuite) {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        suite.expect(MenuBarManagerSupport.hiddenLength(
            osMajor: 26, shownMaxX: 1332, screenFrame: display, cameraMaxX: nil, chrome: 16)
            == MenuBarManagerSupport.offscreenHiddenLength,
            "up to macOS 26 the divider pushes hidden items past the display edge")
        suite.expect(MenuBarManagerSupport.hiddenLength(
            osMajor: 14, shownMaxX: 1332, screenFrame: display, cameraMaxX: nil, chrome: 16)
            == MenuBarManagerSupport.offscreenHiddenLength,
            "Sonoma uses the same off-screen divider")

        // Measured on macOS 27 with a 1920 point display: the divider's left
        // edge stops at 408, and a divider reaching past it is dropped.
        let length27 = MenuBarManagerSupport.hiddenLength(
            osMajor: 27, shownMaxX: 1332, screenFrame: display, cameraMaxX: nil, chrome: 16)
        let leftEdge = 1332 - length27 - 16
        suite.expect(leftEdge >= 408 && leftEdge <= 424,
                     "on macOS 27 the divider stops just short of the measured floor")
        suite.expect(length27 < 924,
                     "on macOS 27 the divider stays below the length that got it evicted")

        let secondDisplay = CGRect(x: -1920, y: -267, width: 1920, height: 1080)
        let lengthOnSecond = MenuBarManagerSupport.hiddenLength(
            osMajor: 27, shownMaxX: -588, screenFrame: secondDisplay, cameraMaxX: nil, chrome: 16)
        suite.expect(lengthOnSecond == length27,
                     "the floor follows the display the divider is on")

        suite.expect(MenuBarManagerSupport.hiddenLength(
            osMajor: 27, shownMaxX: 300, screenFrame: display, cameraMaxX: nil, chrome: 16)
            == MenuBarManagerSupport.materializationLength,
            "a divider already left of the floor never gets a negative length")

        // Measured on macOS 27 with a 1135 point Sidecar display holding the
        // active menu bar: from a shown edge at -539, dividers of 150 to 350
        // points hid the items and longer ones were clamped.
        let sidecar = CGRect(x: -1135, y: 193, width: 1135, height: 789)
        let lengthOnSidecar = MenuBarManagerSupport.hiddenLength(
            osMajor: 27, shownMaxX: -539, screenFrame: sidecar, cameraMaxX: nil, chrome: 16)
        suite.expect(lengthOnSidecar >= 150 && lengthOnSidecar <= 350,
                     "on a Sidecar display the divider stays in the range that hides without a clamp")

        // Measured on macOS 27 with a notched 1512 point display: items fit
        // only right of the camera, which ends at 848.5, and hide into the «
        // from a divider stopping there; the fifth of the display, at 326,
        // got the divider dropped.
        let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let lengthBesideCamera = MenuBarManagerSupport.hiddenLength(
            osMajor: 27, shownMaxX: 973, screenFrame: notched, cameraMaxX: 848.5, chrome: 16)
        let notchedLeftEdge = 973 - lengthBesideCamera - 16
        suite.expect(notchedLeftEdge >= 848.5 && notchedLeftEdge <= 864,
                     "on a notched display the divider stops just right of the camera")

        suite.expect(MenuBarManagerSupport.clampedFloor(
            frame: CGRect(x: 408, y: 1049, width: 1116, height: 33), shownMaxX: 1332) == 408,
            "a frame spilling past its shown edge reports the floor it stopped at")
        suite.expect(MenuBarManagerSupport.clampedFloor(
            frame: CGRect(x: 408, y: 1049, width: 916, height: 33), shownMaxX: 1332) == nil,
            "a divider that fits is not treated as clamped")

        suite.expect(MenuBarManagerSupport.wasCarriedPastCamera(frameMinX: 534, cameraMinX: 663.5),
                     "a divider carried left of the camera by the system overflow is noticed")
        suite.expect(!MenuBarManagerSupport.wasCarriedPastCamera(frameMinX: 857, cameraMinX: 663.5)
            && !MenuBarManagerSupport.wasCarriedPastCamera(frameMinX: -908, cameraMinX: nil),
            "a divider right of the camera, or on a display without one, is left alone")

        suite.expect(MenuBarManagerSupport.seedPosition(
            leftOf: CGRect(x: 1400, y: 1049, width: 129, height: 33), screenFrame: display, gap: 2) == 522,
            "new items are seeded just left of the main icon, counted from the right edge")
        suite.expect(MenuBarManagerSupport.seedPosition(
            leftOf: CGRect(x: 1400, y: 1049, width: 0, height: 33), screenFrame: display, gap: 2) == nil,
            "an unplaced main icon gives no seed")
        suite.expect(MenuBarManagerSupport.seedPosition(
            leftOf: CGRect(x: 3000, y: 1049, width: 40, height: 33), screenFrame: display, gap: 2) == nil,
            "an icon on another display gives no seed for this one")

        suite.expect(MenuBarManagerSupport.wouldHide(
            CGRect(x: 1000, y: 0, width: 40, height: 24), dividerMinX: 1100),
            "the main icon left of the divider would be hidden")
        suite.expect(!MenuBarManagerSupport.wouldHide(
            CGRect(x: 1250, y: 0, width: 40, height: 24), dividerMinX: 1100),
            "the main icon right of the divider stays visible")
        suite.expect(!MenuBarManagerSupport.wouldHide(nil, dividerMinX: 1100),
                     "a main icon out of the bar never blocks hiding")

        suite.expect(MenuBarManagerSupport.pointerIsOnMenuBar(
            CGPoint(x: 900, y: 1070), screenFrames: [display], barHeight: 33),
            "a pointer on the menu bar postpones hiding")
        suite.expect(!MenuBarManagerSupport.pointerIsOnMenuBar(
            CGPoint(x: 900, y: 500), screenFrames: [display], barHeight: 33),
            "a pointer elsewhere lets hiding happen")

        suite.expect(MenuBarManagerSupport.sanitizedRehideSeconds(7) == MenuBarManagerSupport.defaultRehideSeconds
            && MenuBarManagerSupport.sanitizedRehideSeconds(0) == 0
            && MenuBarManagerSupport.sanitizedRehideSeconds(30) == 30,
            "only the offered rehide delays are kept")
        suite.expect(MenuBarManagerSupport.rehideChoices.contains(MenuBarManagerSupport.defaultRehideSeconds),
                     "the default rehide delay is one of the choices")


        suite.expect(AppFeature.menuBarManager.energyProfile == .idle,
                     "nothing runs while icons are hidden: the system « and » show and hide them")

        for language in AppLanguage.allCases {
            let strings = FeatureStrings.menuBarManager(language)
            suite.expect(!strings.title.isEmpty && !strings.howTo.isEmpty && !strings.arrowHint.isEmpty
                && !strings.ownIconWarning.isEmpty && !strings.arrowWarning.isEmpty
                && strings.rehideSecondsFormat.contains("%d"),
                "menu bar manager strings are complete for \(language.rawValue)")
        }
    }
}
