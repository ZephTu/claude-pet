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
    ///
    /// Widened from 400 to 480 because at a 232pt panel every interesting column
    /// was arriving truncated — `20260915-n… thin… 9m` says neither which
    /// session nor what it is doing. The window is mostly transparent, so the
    /// extra 80pt costs nothing on screen; only the panel grows.
    public static let windowSize = CGSize(width: 480, height: 280)

    /// The `#pet` element's own box: 120x120 at right:20 bottom:20 of the
    /// 480x280 stage. Its centre is the SVG's viewBox origin, so a viewBox
    /// coordinate (vx, vy) lands at (petCenter.x + vx, petCenter.y + vy).
    public static let petBox = CGRect(x: 340, y: 140, width: 120, height: 120)

    /// Centre of petBox, and the origin of the SVG viewBox.
    public static let petCenter = CGPoint(x: 400, y: 200)

    /// The robot-at-a-desk drawing is a wide, squat rectangle, so the hit region
    /// is two rectangles rather than the disc the star used to need.
    ///
    /// `bodyBox` spans the desk's full width (viewBox x -46...46) and runs from
    /// just above the antenna's stalk down to the desk's lower edge (viewBox y
    /// -42...26). The upper margin deliberately covers the `urgent` jolt, which
    /// lifts the figure 5pt and tilts it 3° — folding that into a fixed box is
    /// what lets the hit region stop tracking the animation state at all.
    public static let bodyBox = CGRect(x: 354, y: 158, width: 92, height: 68)

    /// The bulb on top of the antenna clears the head entirely, so the body box
    /// cannot reach it. Without its own box the brightest, most clickable-looking
    /// part of the pet would pass clicks straight through to whatever is behind
    /// it. Covers viewBox x -15...-3, y -51...-39: the bulb (centre -8.7,-40.5,
    /// r 4.6) plus the same 5pt of urgent lift.
    public static let antennaBox = CGRect(x: 385, y: 149, width: 12, height: 12)

    /// The cat's single box, measured off the artwork rather than guessed.
    ///
    /// It is the union of the alpha bounding boxes of all five textures, mapped
    /// through the renderer's own 6% margin (`p = 0.06 + p * 0.88`) into the
    /// 120x120 pet box. One rectangle for all five poses, for the same reason
    /// the robot has one: a hit region that tracked the animation would change
    /// under the cursor.
    ///
    /// The cat has no antenna, so there is no second box — its lamp is drawn by
    /// the host inside this rectangle.
    public static let catBodyBox = CGRect(x: 354, y: 148, width: 98, height: 104)

    /// The rectangles that count as "the pet" for this skin.
    public static func hitBoxes(skin: PetSkin) -> [CGRect] {
        switch skin {
        case .robot: return [bodyBox, antennaBox]
        case .cat: return [catBodyBox]
        }
    }

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

    /// How far the WINDOW has to move so the PET does not move when the layout
    /// flips.
    ///
    /// Flipping slides the drawing 320pt across the window. Left uncompensated
    /// that is a 320pt leap on screen, and it happens at the left edge — where
    /// the leap is straight out of view. The pet must stay exactly where the
    /// hand that dragged it let go.
    public static func flipShift(toMirrored: Bool) -> CGFloat {
        let delta = petBox.minX - mirroredPetBox.minX
        return toMirrored ? delta : -delta
    }

    /// How far back towards the middle the pet must come before a mirrored
    /// layout flips back. Without it a pet parked on the line flaps between
    /// sides on every one-pixel nudge.
    public static let flipHysteresis: CGFloat = 24

    /// Should the layout flip, given where the window sits on its screen?
    ///
    /// Measured through the PET, not the window. Flipping moves the window (see
    /// `flipShift`), so a rule that read the window's own origin would give a
    /// different answer the instant it acted on its previous one, and the
    /// layout would oscillate.
    ///
    /// - Parameters:
    ///   - windowOrigin: the window's lower-left corner in screen coordinates.
    ///   - visibleFrame: the screen's usable area.
    ///   - mirrored: the layout the window is in right now.
    public static func shouldMirror(windowOrigin: CGPoint, visibleFrame: CGRect,
                                    mirrored: Bool = false) -> Bool {
        // Where the window would be for this same pet position, unmirrored.
        let petMinX = windowOrigin.x + (mirrored ? mirroredPetBox.minX : petBox.minX)
        let origin = petMinX - petBox.minX
        // Only flip if flipping actually helps: on a window already hanging off
        // the right edge, mirroring would push the panel off THAT side instead.
        let helps = origin + windowSize.width <= visibleFrame.maxX
        if mirrored {
            return origin < visibleFrame.minX + flipHysteresis && helps
        }
        // Would the panel's left edge fall off the screen as things stand?
        return origin < visibleFrame.minX && helps
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
    /// a 480x280 window passes clicks through to whatever is underneath
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
        mirrored isMirrored: Bool = false,
        skin: PetSkin = .robot
    ) -> Bool {
        if let panel, panel.contains(point) { return true }
        if let bubble, bubble.contains(point) { return true }
        return hitBoxes(skin: skin).contains {
            (isMirrored ? mirrored($0) : $0).contains(point)
        }
    }

    /// Is the pointer on the figure itself, in this skin and this layout?
    ///
    /// The same rectangle a click uses, because "the pointer is on the pet" has
    /// to have ONE answer — resting on the cat's paws and clicking the cat's
    /// paws cannot be two different questions. It was two: the hover readout
    /// asked `bodyBox` directly, which is the ROBOT's desk, so a quarter of the
    /// cat (its lower body) and all of it on a mirrored layout showed no quota
    /// at all while still being clickable.
    public static func isOnPet(_ point: CGPoint, skin: PetSkin = .robot,
                               mirrored isMirrored: Bool = false) -> Bool {
        let box = clickBox(skin: skin)
        return (isMirrored ? mirrored(box) : box).contains(point)
    }

    /// The one box a click on the figure must land in, for this skin.
    ///
    /// The robot's antenna is deliberately not included: clicking the bulb
    /// should not toggle the panel any more than clicking the desk should, and
    /// the antenna box exists only so the brightest part of the drawing does not
    /// pass clicks through to whatever is behind it.
    public static func clickBox(skin: PetSkin) -> CGRect {
        switch skin {
        case .robot: return bodyBox
        case .cat: return catBodyBox
        }
    }
}
