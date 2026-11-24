import XCTest
import Darwin

extension SimFixtureTests {
    func testTRUST_symbols() {
        for name in ["AXIsProcessTrusted", "_AXSApplicationAccessibilityEnabled", "_AXSAutomationEnabled"] {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { say("TRUST | \(name) | dlsym nil"); continue }
            typealias F = @convention(c) () -> UInt8
            let v = unsafeBitCast(p, to: F.self)()
            say("TRUST | \(name) | found | returns \(v)")
        }
    }
}
