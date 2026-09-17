import Foundation
import CoreGraphics

/// The single source of truth for where things sit inside the pet window.
///
/// Every number here is also written into Resources/pet/pet.css — the two files
/// MUST agree, and pet.css carries a pointer back here. Keeping the numbers in
/// ClaudePetCore (rather than in the AppKit layer) is what makes the hit-testing
/// geometry unit-testable without a window server.
///
/// Coordinates are CSS coordinates: origin top-left, y grows downward, 1 unit =
/// 1 point = 1 CSS pixel. The AppKit layer converts once, at the boundary.
public enum PetLayout {
    /// The window is big enough to hold the pet AND the expanded panel beside
    /// it. The panel used to be laid out at `right: 100%` of a 160pt-wide body,
    /// which put it entirely off-window at negative x.
    public static let windowSize = CGSize(width: 400, height: 280)

    /// The `#pet` element's own box: 120x120 at right:20 bottom:20 of the
    /// 400x280 stage. Its centre is the SVG's viewBox origin, so a viewBox
    /// coordinate (vx, vy) lands at (petCenter.x + vx, petCenter.y + vy).
    public static let petBox = CGRect(x: 260, y: 140, width: 120, height: 120)

    /// Centre of petBox, and the origin of the SVG viewBox.
    public static let petCenter = CGPoint(x: 320, y: 200)

    /// The robot-at-a-desk drawing is a wide, squat rectangle, so the hit region
    /// is two rectangles rather than the disc the star used to need.
    ///
    /// `bodyBox` spans the desk's full width (viewBox x -46...46) and runs from
    /// just above the antenna's stalk down to the desk's lower edge (viewBox y
    /// -42...26). The upper margin deliberately covers the `urgent` jolt, which
    /// lifts the figure 5pt and tilts it 3° — folding that into a fixed box is
    /// what lets the hit region stop tracking the animation state at all.
    public static let bodyBox = CGRect(x: 274, y: 158, width: 92, height: 68)

    /// The bulb on top of the antenna clears the head entirely, so the body box
    /// cannot reach it. Without its own box the brightest, most clickable-looking
    /// part of the pet would pass clicks straight through to whatever is behind
    /// it. Covers viewBox x -15...-3, y -51...-39: the bulb (centre -8.7,-40.5,
    /// r 4.6) plus the same 5pt of urgent lift.
    public static let antennaBox = CGRect(x: 305, y: 149, width: 12, height: 12)

    /// Where `#pet` sits once the layout flips: same size, other side.
    public static var mirroredPetBox: CGRect {
        CGRect(x: windowSize.width - petBox.maxX, y: petBox.origin.y,
               width: petBox.width, height: petBox.height)
    }

    /// The same box on a mirrored layout.
    ///
    /// When the pet is dragged to the left edge of a display, the panel — which
    /// lives in the window's left 232pt — would open off-screen. Rather than
    /// fencing the window in (which would stop the pet ever sitting near the
    /// left edge at all, since most of the window is transparent), the layout
    /// flips: pet on the left, panel on the right.
    ///
    /// This is a TRANSLATION, not a reflection, and the difference is not
    /// academic. Flipping moves the `#pet` element to the other side; it does
    /// not mirror the drawing inside it, so the robot still faces the same way
    /// and the antenna bulb stays left of centre. Reflecting the boxes instead
    /// happens to give the right answer for `bodyBox`, which is symmetric inside
    /// the pet, and the wrong one for `antennaBox`, which is not — the bulb
    /// ended up outside its own hit region.
    public static func mirrored(_ box: CGRect) -> CGRect {
        box.offsetBy(dx: mirroredPetBox.minX - petBox.minX, dy: 0)
    }

    /// Should the layout flip, given where the window sits on its screen?
    ///
    /// - Parameters:
    ///   - windowOrigin: the window's lower-left corner in screen coordinates.
    ///   - visibleFrame: the screen's usable area.
    public static func shouldMirror(windowOrigin: CGPoint, visibleFrame: CGRect) -> Bool {
        // Would the panel's left edge fall off the screen as things stand?
        let panelLeft = windowOrigin.x
        guard panelLeft < visibleFrame.minX else { return false }
        // Only flip if flipping actually helps: on a window already hanging off
        // the right edge, mirroring would push the panel off THAT side instead.
        return windowOrigin.x + windowSize.width <= visibleFrame.maxX
    }

    /// Where to put the window so the pet stays reachable on this screen.
    ///
    /// Returns nil when the current spot is fine. Only the PET has to stay on
    /// screen, not the whole window: most of the window is transparent, and
    /// insisting all 400pt of it fit would stop the pet ever sitting near an
    /// edge — which is exactly where people put it.
    ///
    /// - Parameters:
    ///   - windowOrigin: the window's lower-left corner in screen coordinates.
    ///   - visibleFrame: the screen's usable area.
    ///   - mirrored: whether the layout is flipped, which moves the pet.
    public static func rescued(
        windowOrigin: CGPoint,
        visibleFrame: CGRect,
        mirrored isMirrored: Bool = false
    ) -> CGPoint? {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        let pet = isMirrored ? mirroredPetBox : petBox
        // CSS coordinates run downward from the window's top; screen ones run
        // upward from its bottom. The pet's box has to be flipped to match.
        let petScreen = CGRect(
            x: windowOrigin.x + pet.minX,
            y: windowOrigin.y + (windowSize.height - pet.maxY),
            width: pet.width, height: pet.height)

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if petScreen.minX < visibleFrame.minX { dx = visibleFrame.minX - petScreen.minX }
        if petScreen.maxX > visibleFrame.maxX { dx = visibleFrame.maxX - petScreen.maxX }
        if petScreen.minY < visibleFrame.minY { dy = visibleFrame.minY - petScreen.minY }
        if petScreen.maxY > visibleFrame.maxY { dy = visibleFrame.maxY - petScreen.maxY }
        guard dx != 0 || dy != 0 else { return nil }
        return CGPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy)
    }

    /// Is this point over something the user can actually see?
    ///
    /// Used to drive `ignoresMouseEvents`, so that the transparent majority of
    /// a 400x280 window passes clicks through to whatever is underneath
    /// (design doc section 4) instead of eating them.
    ///
    /// The regions are rectangles, not the figure's outline: sampling real pixel
    /// alpha would mean `takeSnapshot`, which is async and far too expensive to
    /// run on every mouse-move.
    ///
    /// - Parameters:
    ///   - point: cursor position in CSS coordinates.
    ///   - panel: the expanded panel's rect, or nil when collapsed.
    ///   - bubble: the speech bubble's rect, or nil when hidden.
    public static func isOpaque(
        at point: CGPoint,
        panel: CGRect?,
        bubble: CGRect?,
        mirrored isMirrored: Bool = false
    ) -> Bool {
        if let panel, panel.contains(point) { return true }
        if let bubble, bubble.contains(point) { return true }
        let body = isMirrored ? mirrored(bodyBox) : bodyBox
        let antenna = isMirrored ? mirrored(antennaBox) : antennaBox
        return body.contains(point) || antenna.contains(point)
    }
}
