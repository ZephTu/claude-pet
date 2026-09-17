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
        bubble: CGRect?
    ) -> Bool {
        if let panel, panel.contains(point) { return true }
        if let bubble, bubble.contains(point) { return true }
        return bodyBox.contains(point) || antennaBox.contains(point)
    }
}
