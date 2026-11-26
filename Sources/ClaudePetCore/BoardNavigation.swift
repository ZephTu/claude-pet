import Foundation

/// What the board's window on the Mac may show, and whom its native bridge answers.
///
/// The bridge can save and run a shell job, type into terminals, and answer permission prompts:
/// only the board's own pages, served under `pet://app/`, may reach it. A link to the web (the
/// guide links to Tailscale's site, a task's refs to Jira) opens in the browser instead of taking
/// over the window — a page from anywhere else would get the bridge, and the board has no Back
/// button to leave it by.
public enum BoardNavigation {
    /// The board's own pages: `pet://app/…` — see PetSchemeHandler, which serves them.
    public static let scheme = "pet"
    public static let host = "app"

    public enum Decision: Equatable, Sendable {
        /// One of the board's own pages (or a part of one).
        case allow
        /// A web or mail link: the browser (or mail app) opens it; the board stays.
        case openOutside
        /// Anything else: nothing happens.
        case cancel
    }

    /// - Parameter mainFrame: whether the navigation replaces the window's page (a link that
    ///   opens a new window counts: the board has none to give it).
    public static func decide(url: URL?, mainFrame: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case Self.scheme:
            return url.host?.lowercased() == host ? .allow : .cancel
        case "http", "https", "mailto":
            return mainFrame ? .openOutside : .cancel
        default:
            return .cancel
        }
    }

    /// Whether a message to the bridge came from the board itself: its main frame, on `pet://app`.
    /// An embedded frame, or a page that got into the window some other way, is turned away.
    public static func trusted(mainFrame: Bool, scheme: String, host: String) -> Bool {
        mainFrame && scheme.lowercased() == Self.scheme && host.lowercased() == Self.host
    }
}
