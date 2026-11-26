// PokiCore on a Mac, as a stdio MCP server, for an iOS Simulator with WebDriverAgent (issue #609,
// phase 5): the same look, do, skills and status an iPhone serves, so a Simulator answers an agent
// as a phone does. Poki Setup's poki-mcp starts it (`poki-setup mcp serve --simulator`) and speaks
// MCP to it one JSON-RPC message per line. macOS only; elsewhere it says so and exits.
//
// POKI_WDA_URL   the WebDriverAgent address (default http://127.0.0.1:8100)
// POKI_SIM_UDID  the Simulator for screenshots apart from WDA (default: booted)
import Foundation
#if os(macOS)
import PokiCore
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

final class Host: CoreHost, @unchecked Sendable {
    struct NoKey: Error {}
    let simulator = ProcessInfo.processInfo.environment["POKI_SIM_UDID"] ?? "booted"
    func signingKey() throws -> RelayKey { throw NoKey() }
    func accessHashes() -> [String] { [] }
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: width * 3] as CFDictionary) else { throw NoKey() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw NoKey() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NoKey() }
        return out as Data
    }
    func runnerState() -> RunnerState { .running }
    func restartRunner() {}
    func warmUp() {}
    /// `simctl io <udid> screenshot`, apart from WDA, when WDA gives no picture.
    func screenshotWithoutRunner() async -> Data? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("poki-core-mac-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", simulator, "screenshot", "--type=png", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
        } catch { return nil }
        return try? Data(contentsOf: path)
    }
}

let url = URL(string: ProcessInfo.processInfo.environment["POKI_WDA_URL"] ?? "http://127.0.0.1:8100")!
let host = Host()
let core = PokiCore(config: CoreConfig(runnerURL: url, treeFormat: "xml"), host: host)
let session = LockedSession()

final class LockedSession: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? { get { lock.withLock { id } } set { lock.withLock { id = newValue } } }
}

let out = FileHandle.standardOutput
let writeLock = NSLock()
let group = DispatchGroup()
var counter = 0
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    counter += 1
    let id = "m\(counter)"
    group.enter()
    Task {
        var headers = ["content-type": "application/json", "accept": "application/json, text/event-stream"]
        if let s = session.value { headers["mcp-session-id"] = s }
        let response = await core.handle(RelayRequest(id: id, method: "POST", headers: headers, body: line))
        if let s = response.headers["mcp-session-id"] { session.value = s }
        if !response.body.isEmpty {
            writeLock.withLock { out.write(Data((response.body + "\n").utf8)) }
        }
        group.leave()
    }
    // One message at a time, so the session from initialize is there for the next one.
    group.wait()
}
#else
FileHandle.standardError.write(Data("poki-core-mac runs on macOS only.\n".utf8))
exit(1)
#endif
