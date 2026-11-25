import ClaudePetCore
import Foundation

/// The Mac's Tailscale, through its command line: who this Mac is on its tailnet, and whether a
/// peer that connects from a Tailscale address is a device of the same user's (BoardServer lets
/// only those in — see RemoteAccess.isTailnet). Nothing is changed in Tailscale's settings.
@MainActor
final class Tailnet {
    static let shared = Tailnet()

    /// The last reading of `tailscale status`; nil until one has come back, or with no Tailscale.
    private(set) var me: RemoteAccess.TailnetSelf?
    /// Why there's no reading: Tailscale not installed, or not answering.
    private(set) var problem: String?
    private var readAt: Date?
    private var reading: Task<RemoteAccess.TailnetSelf?, Never>?
    /// whois answers by address: a device's Tailscale address stays its own.
    private var verdicts: [String: (ok: Bool, at: Date)] = [:]
    private var asking: [String: Task<Bool, Never>] = [:]

    /// Where Tailscale's command line is: the standalone app's, Homebrew's, or inside the app.
    private static let cli: String? = [
        "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// This Mac on the tailnet, read again when the last reading is over 30 seconds old.
    @discardableResult
    func current(force: Bool = false) async -> RemoteAccess.TailnetSelf? {
        if !force, let readAt, Date().timeIntervalSince(readAt) < 30 { return me }
        if let reading { return await reading.value }
        let task = Task { () -> RemoteAccess.TailnetSelf? in
            guard Self.cli != nil else {
                problem = L("Tailscale isn't installed on this Mac", "这台 Mac 没装 Tailscale")
                return nil
            }
            guard let data = await Self.run(["status", "--json", "--peers=false"]),
                  let me = RemoteAccess.tailnetSelf(statusJSON: data) else {
                problem = L("Tailscale isn't answering — is it running?", "Tailscale 没有回应——它开着吗？")
                return nil
            }
            problem = me.running ? nil : L("Tailscale isn't connected", "Tailscale 没有连上")
            return me
        }
        reading = task
        let value = await task.value
        reading = nil
        me = value
        readAt = Date()
        return value
    }

    /// Reads again in the background when stale: for Settings, which can't wait on it.
    func refresh() { Task { await current() } }

    /// Whether the peer at `address` is a device of the user this Mac is logged in as. Asked once
    /// per address every couple of minutes (a page load opens several connections at once).
    func allows(_ address: String) async -> Bool {
        let now = Date()
        if let v = verdicts[address], now.timeIntervalSince(v.at) < (v.ok ? 120 : 30) { return v.ok }
        if let pending = asking[address] { return await pending.value }
        let task = Task { () -> Bool in
            guard let me = await current(), me.running, let login = me.login,
                  let data = await Self.run(["whois", "--json", address]) else { return false }
            return RemoteAccess.tailnetOwnDevice(whoisJSON: data, login: login)
        }
        asking[address] = task
        let ok = await task.value
        asking[address] = nil
        if verdicts.count > 500 { verdicts = verdicts.filter { now.timeIntervalSince($0.value.at) < 120 } }
        verdicts[address] = (ok, Date())
        if !ok { NSLog("ClaudePet: phone access — refused \(address) over Tailscale: not a device of this Mac's user") }
        return ok
    }

    /// `tailscale …`'s output, or nil when it fails or takes over five seconds.
    private static func run(_ args: [String]) async -> Data? {
        guard let cli else { return nil }
        return await Task.detached { () -> Data? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return p.terminationStatus == 0 ? data : nil
        }.value
    }
}
