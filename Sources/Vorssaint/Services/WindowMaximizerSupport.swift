// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

enum WindowMaximizerSupport {
    /// An app on the exception list keeps the green button's own behavior, so
    /// a game, an emulator or a player can still enter macOS full screen.
    static func excludes(bundleIdentifier: String?, excludedBundleIdentifiers: [String]) -> Bool {
        guard let bundleIdentifier else { return false }
        return Defaults.sanitizedBundleIdentifierList(excludedBundleIdentifiers).contains(bundleIdentifier)
    }

    /// Some apps keep a window edge out from under a Dock at the side of the
    /// screen: a size that grows is held just short of the Dock, but one that
    /// shrinks from beyond the screen edge onto the Dock's own boundary is
    /// pushed back out to the edge. A window dragged in from a wider display
    /// hits the second case, so the result is larger than the target, not
    /// smaller as with an app that commits late or refuses the frame.
    static func overshoots(_ actual: CGSize, target: CGSize, tolerance: CGFloat) -> Bool {
        actual.width > target.width + tolerance || actual.height > target.height + tolerance
    }

    /// Shrinking below the target and then growing into it goes through the
    /// path those apps only clamp. Stopping short by exactly the tolerance means
    /// an app that also refuses the regrow still ends within it.
    static func approachSize(for target: CGSize, tolerance: CGFloat) -> CGSize {
        CGSize(width: max(1, target.width - tolerance), height: max(1, target.height - tolerance))
    }
}
