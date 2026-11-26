import ClaudePetCore
import Foundation

/// The board's polled reads, shared between the Mac's window and the phones (SharedReads).
enum SharedReadsTests {
    /// A counter and a settable clock the reads can touch from any thread.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    }

    /// Runs async test code to the end from the synchronous runner.
    static func wait(_ body: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await body(); done.signal() }
        done.wait()
    }

    static func run(_ t: Harness) {
        print("\n-- shared board reads")

        t.check("board, sessions and status are kept 2s, agents longer",
                SharedReads.ttl("board") == 2 && SharedReads.ttl("sessions") == 2 && SharedReads.ttl("status") == 2
                && (SharedReads.ttl("agents") ?? 0) >= 15 && SharedReads.ttl("peek") == nil)
        t.check("reads change nothing; saves and unknown ops do",
                !SharedReads.changes("board") && !SharedReads.changes("pet") && !SharedReads.changes("peek")
                && SharedReads.changes("set") && SharedReads.changes("todo") && SharedReads.changes("launch")
                && SharedReads.changes("some-new-op"))

        let box = Box()
        let reads = SharedReads(now: { box.now })
        let fetch: @Sendable () async -> SharedReads.Answer = {
            let n = box.bump()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .init(text: "v\(n)", error: nil)
        }

        // Several boards asking at once: one read, the same answer for all.
        final class Answers: @unchecked Sendable { var list: [String?] = [] }
        let together = Answers()
        wait {
            await withTaskGroup(of: String?.self) { g in
                for _ in 0..<5 { g.addTask { await reads.read("board", ttl: 2, fetch).text } }
                for await a in g { together.list.append(a) }
            }
        }
        t.check("reads at the same moment run once and share the answer",
                box.count == 1 && together.list.count == 5 && Set(together.list.compactMap { $0 }) == ["v1"])

        final class One: @unchecked Sendable { var v: String?; var w: String? }
        let o = One()
        wait { o.v = await reads.read("board", ttl: 2, fetch).text }
        t.check("a finished read answers again within its ttl", o.v == "v1" && box.count == 1)

        box.advance(2.5)
        wait { o.v = await reads.read("board", ttl: 2, fetch).text }
        t.check("past its ttl it is read again", o.v == "v2" && box.count == 2)

        wait { await reads.changed(); o.v = await reads.read("board", ttl: 2, fetch).text }
        t.check("a change drops what was kept", o.v == "v3" && box.count == 3)

        wait { o.v = await reads.read("sessions", ttl: 2, fetch).text }
        t.check("each op is kept apart", o.v == "v4" && box.count == 4)

        // A change while a read runs: the read after it doesn't join the one started before.
        wait {
            async let first = reads.read("agents", ttl: 20, fetch)
            try? await Task.sleep(nanoseconds: 10_000_000)
            await reads.changed()
            let second = await reads.read("agents", ttl: 20, fetch)
            o.v = await first.text
            o.w = second.text
        }
        t.check("a read after a change doesn't join one from before it",
                o.v == "v5" && o.w == "v6" && box.count == 6)

        // A failed read isn't kept.
        let failing = Box()
        let fail: @Sendable () async -> SharedReads.Answer = { _ = failing.bump(); return .init(text: nil, error: "boom") }
        wait { o.v = await reads.read("status", ttl: 2, fail).error; _ = await reads.read("status", ttl: 2, fail) }
        t.check("a failed read is not kept", o.v == "boom" && failing.count == 2)
    }
}
