import Foundation
import XCTest
@testable import PokiCore

/// Issue #609: Poki Setup's poki-mcp reaches the phone over USB or Wi-Fi without the relay.
final class LocalLinkTests: XCTestCase {
    /// Signatures in these tests are the message reversed (FakeKey's), so the fake checks that.
    final class Host: LocalLinkHost, @unchecked Sendable {
        let trusted = LockedBox<Set<String>>([])
        let asked = LockedBox<[LocalClient]>([])
        let answer = LockedBox(true)
        func signingKey() throws -> RelayKey { FakeKey() }
        func verify(signature: Data, of message: Data, publicKey: Data) -> Bool { signature == Data(message.reversed()) }
        func isTrusted(computer id: String) -> Bool { trusted.value.contains(id) }
        func approve(computer: LocalClient) async -> Bool { asked.update { $0.append(computer) }; return answer.value }
        func trust(computer: LocalClient) { trusted.update { _ = $0.insert(computer.id) } }
    }

    func expectSoon(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await eventually(2, condition)
        XCTAssertTrue(ok, file: file, line: line)
    }

    let computerKey = Data((100..<132).map { UInt8($0) })

    func hello(for challenge: String, transport: String = "usb", tamper: Bool = false) throws -> String {
        let c = try JSON.parse(challenge)
        let nonce = Data(base64Encoded: c["nonce"]!.string!)!
        var message = Data("poki-local-v1:\(c["phone"]!.string!):\(transport):".utf8); message.append(nonce)
        var sig = Data(message.reversed()); if tamper { sig[0] ^= 1 }
        let hello: JSON = ["t": "hello", "v": 1, "key": .string(computerKey.base64EncodedString()), "sig": .string(sig.base64EncodedString()),
                           "cnonce": .string(Data(repeating: 7, count: 32).base64EncodedString()),
                           "client": ["kind": "computer", "id": .string(base32(computerKey)), "name": "Test Mac", "app": "poki-mcp", "version": "0.5.0", "transport": .string(transport), "agent": "claude-code"]]
        return hello.serialized()
    }

    func link(_ host: Host, _ seen: LockedBox<[RelayRequest]>) -> LocalLink {
        LocalLink(host: host) { request in
            seen.update { $0.append(request) }
            return RelayResponse(id: request.id, status: 200, headers: ["content-type": "application/json"], body: "{\"ok\":true}")
        }
    }

    func testAFirstComputerWaitsForTheOwnerThenItsRequestsAreAnsweredAndMarkedLocal() async throws {
        let host = Host(), seen = LockedBox<[RelayRequest]>([]), socket = FakeSocket()
        let served = Task { await link(host, seen).serve(socket, transport: .usb) }
        await expectSoon { socket.sent.count == 1 }
        socket.push(try hello(for: socket.sent[0]))
        await expectSoon { socket.sent.contains { $0.contains("\"ready\"") } }
        XCTAssertEqual(host.asked.value.map(\.describe), ["Test Mac over USB"])
        XCTAssertTrue(host.trusted.value.contains(base32(computerKey)))
        // The phone proves itself back: its key signs the computer's nonce.
        let ready = try JSON.parse(socket.sent.last!)
        var expected = Data("poki-local-v1-phone:\(base32(computerKey)):".utf8); expected.append(Data(repeating: 7, count: 32))
        XCTAssertEqual(Data(base64Encoded: ready["sig"]!.string!), Data(expected.reversed()))

        socket.push((["t": "req", "id": "r1", "method": "POST", "headers": ["x-poki-connector": "forged", "content-type": "application/json"], "body": "{}"] as JSON).serialized())
        await expectSoon { socket.sent.contains { $0.contains("\"res\"") } }
        XCTAssertEqual(seen.value.first?.headers[PokiCore.connectorHeader], "local:\(base32(computerKey))", "set by the handshake, never by the computer")
        XCTAssertEqual(seen.value.first?.headers[PokiCore.transportHeader], "usb")
        socket.push("ping")
        await expectSoon { socket.sent.last == "pong" }
        socket.close(code: 1000, reason: "")
        await served.value
    }

    func testATrustedComputerIsNotAskedAgain() async throws {
        let host = Host(), socket = FakeSocket()
        host.trusted.value = [base32(computerKey)]
        let served = Task { await link(host, LockedBox([])).serve(socket, transport: .wifi) }
        await expectSoon { socket.sent.count == 1 }
        socket.push(try hello(for: socket.sent[0], transport: "wifi"))
        await expectSoon { socket.sent.contains { $0.contains("\"ready\"") } }
        XCTAssertTrue(host.asked.value.isEmpty)
        socket.close(code: 1000, reason: "")
        await served.value
    }

    func testABadSignatureADeclineOrASignatureForAnotherTransportIsRefusedBeforeAnyRequest() async throws {
        for (tamper, transport, answer) in [(true, "usb", true), (false, "usb", false), (false, "wifi", true)] {
            let host = Host(), seen = LockedBox<[RelayRequest]>([]), socket = FakeSocket()
            host.answer.value = answer
            let served = Task { await link(host, seen).serve(socket, transport: .usb) }
            await expectSoon { socket.sent.count == 1 }
            socket.push(try hello(for: socket.sent[0], transport: transport, tamper: tamper))
            socket.push((["t": "req", "id": "r1", "body": "{}"] as JSON).serialized())
            await served.value
            XCTAssertTrue(socket.sent.contains { $0.contains("\"close\"") }, "\(socket.sent)")
            XCTAssertFalse(socket.sent.contains { $0.contains("\"ready\"") })
            XCTAssertTrue(seen.value.isEmpty)
            XCTAssertTrue(host.trusted.value.isEmpty)
        }
    }
}
