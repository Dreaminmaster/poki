import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let appURL = root.appendingPathComponent("Poki.bundle")
let contents = appURL.appendingPathComponent("Contents")
let resources = contents.appendingPathComponent("Resources")
let plugins = contents.appendingPathComponent("PlugIns/PokiWidgets.appex/Contents")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
func plist(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}
try plist([
    "CFBundleIdentifier": "nz.zheha.poki.TESTTEAM", "CFBundleVersion": "100",
    "CFBundleShortVersionString": "0.4.0", "PokiAppGroup": "group.nz.zheha.poki.TESTTEAM",
]).write(to: contents.appendingPathComponent("Info.plist"))
try plist(["CFBundleIdentifier": "nz.zheha.poki.TESTTEAM.widgets"]).write(to: plugins.appendingPathComponent("Info.plist"))
let profileURL = resources.appendingPathComponent("embedded.mobileprovision")
func profile(_ certs: [Data]) throws {
    try plist([
        "TeamIdentifier": ["TESTTEAM"], "DeveloperCertificates": certs,
        "Entitlements": ["application-identifier": "TESTTEAM.nz.zheha.poki.TESTTEAM", "com.apple.security.application-groups": ["group.nz.zheha.poki.TESTTEAM"]],
    ]).write(to: profileURL)
}
try profile([Data("abc".utf8)])
let channel = root.appendingPathComponent("channel.json")
let request = root.appendingPathComponent("request.json")
try Data(#"{"channel":"alpha"}"#.utf8).write(to: channel)
try Data(#"{"nonce":"first-request"}"#.utf8).write(to: request)
guard let app = Bundle(url: appURL), let first = PokiUpdateInfo.read(app: app, channelFile: channel, requestFile: request) else {
    fatalError("A complete bundle must produce public update information")
}
precondition(first["version"] as? String == "0.4.0")
precondition(first["build"] as? String == "100")
precondition(first["channel"] as? String == "alpha")
precondition(first["nonce"] as? String == "first-request")
precondition(first["extensions"] as? [String] == ["nz.zheha.poki.TESTTEAM.widgets"])
precondition(first["certificate_sha256"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
precondition(first["key_pkcs8_pem"] == nil)
try Data(#"{"nonce":"second-request"}"#.utf8).write(to: request)
let fresh = PokiUpdateInfo.read(app: app, channelFile: channel, requestFile: request)
precondition(fresh?["nonce"] as? String == "second-request")
try profile([Data("abc".utf8), Data("different-certificate".utf8)])
precondition(PokiUpdateInfo.read(app: app, channelFile: channel, requestFile: request) == nil)
try profile([Data("abc".utf8)])
try Data(#"{"channel":"unknown"}"#.utf8).write(to: channel)
precondition(PokiUpdateInfo.read(app: app, channelFile: channel, requestFile: request) == nil)
print("Public update snapshot checks passed")
