import Foundation

/// Minimal assertion harness.
/// Only Command Line Tools are installed on this machine, so neither XCTest nor
/// swift-testing is available; this stands in for them.
public final class Harness {
    private var failures = 0
    private var passes = 0

    public init() {}

    public func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passes += 1
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)")
        }
    }

    public func finish() -> Never {
        print(failures == 0 ? "\nALL PASS (\(passes))" : "\n\(failures) FAILED, \(passes) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
