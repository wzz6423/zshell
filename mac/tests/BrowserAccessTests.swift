import Foundation
import Network

@main
struct BrowserAccessTests {
    nonisolated static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    nonisolated static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); fatalError(message) } catch {}
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try BrowserAccessStorage.prepare(root)
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try BrowserAccessAuthorization(directory: root, now: { date })
        let origin = "https://192.168.0.10:7443"
        let pairing = try store.begin(name: "Test Browser 中文", address: "192.168.0.20", origin: origin)
        check(store.authenticate(token: pairing.ticket, origin: origin) == nil, "pairing tickets cannot authenticate")
        check(store.status(ticket: pairing.ticket, address: "192.168.0.21", origin: origin).state == "expired", "pairing is peer-bound")
        check(store.status(ticket: pairing.ticket, address: "192.168.0.20", origin: "https://evil.example").state == "expired", "pairing is origin-bound")
        let request = store.pairings[0]
        try store.approve(request.id)
        let approved = store.status(ticket: pairing.ticket, address: "192.168.0.20", origin: origin)
        guard let token = approved.token else { fatalError("approved token") }
        check(approved.state == "approved" && BrowserAccessSecret.isValid(token), "approval returns secure credential")
        check(store.status(ticket: pairing.ticket, address: "192.168.0.20", origin: origin).state == "expired", "ticket is consumed once")
        let stored = try Data(contentsOf: root.appendingPathComponent("clients.json"))
        check(!String(decoding: stored, as: UTF8.self).contains(token), "persist only credential digest")
        check(store.authenticate(token: token, origin: "http://192.168.0.10:7443") == nil, "credential cannot downgrade HTTPS")
        let reloaded = try BrowserAccessAuthorization(directory: root, now: { date })
        guard let client = reloaded.authenticate(token: token, origin: origin) else { fatalError("saved authorization") }
        try reloaded.revoke(client.id)
        check(reloaded.authenticate(token: token, origin: origin) == nil && !reloaded.isAuthorized(client.id, origin: origin), "revocation rejects input immediately")
        let pending = try store.begin(name: "Expired", address: "192.168.0.20", origin: origin)
        date = date.addingTimeInterval(BrowserAccessLimits.pairingSeconds + 1)
        check(store.status(ticket: pending.ticket, address: "192.168.0.20", origin: origin).state == "expired", "pending pairing expires")
        date = date.addingTimeInterval(90 * 24 * 3600)
        check(store.authenticate(token: token, origin: origin) == nil, "client authorization expires")
        for _ in 0..<12 { _ = store.allowAttempt("192.168.0.90") }
        check(!store.allowAttempt("192.168.0.90"), "authentication attempts are bounded")
        date = date.addingTimeInterval(61)
        check(store.allowAttempt("192.168.0.90"), "bounded rate limit recovers")

        let scope = BrowserAccessScope(address: "192.168.0.10", port: 7443, usesTLS: true)
        func http(_ head: String, body: String = "") -> Data { Data((head + "\r\n\r\n" + body).utf8) }
        let valid = http("POST /api/pair HTTP/1.1\r\nHost: \(scope.host)\r\nOrigin: \(scope.origin)\r\nContent-Type: application/json\r\nContent-Length: 2", body: "{}")
        check(try BrowserAccessHTTPRequest.next(in: valid, scope: scope)?.0.body == Data("{}".utf8), "valid origin-bound HTTP body")
        for invalid in [
            http("GET / HTTP/1.1\r\nHost: evil.example:7443"),
            http("GET / HTTP/1.1\r\nHost: \(scope.host)\r\nOrigin: https://evil.example"),
            http("GET / HTTP/1.1\r\nHost: \(scope.host)\r\nHost: \(scope.host)"),
            http("GET /../clients.json HTTP/1.1\r\nHost: \(scope.host)"),
            http("GET /%2e%2e/clients.json HTTP/1.1\r\nHost: \(scope.host)"),
            http("GET /terminal?token=secret HTTP/1.1\r\nHost: \(scope.host)"),
            http("GET / HTTP/1.1\r\nHost: \(scope.host)\r\nTransfer-Encoding: chunked"),
            http("POST /api/pair HTTP/1.1\r\nHost: \(scope.host)\r\nContent-Type: application/json\r\nContent-Length: 2", body: "{}"),
            http("POST /api/pair HTTP/1.1\r\nHost: \(scope.host)\r\nOrigin: \(scope.origin)\r\nContent-Type: application/json\r\nContent-Length: 4097"),
            http("GET https://evil.example/ HTTP/1.1\r\nHost: \(scope.host)"),
        ] { rejects({ _ = try BrowserAccessHTTPRequest.next(in: invalid, scope: scope) }, "malicious HTTP accepted") }
        let handshake = http("GET /terminal HTTP/1.1\r\nHost: \(scope.host)\r\nOrigin: \(scope.origin)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits")
        let requestHead = try BrowserAccessHTTPRequest.next(in: handshake, scope: scope)!.0
        check(try requestHead.webSocketAccept() == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "browser WebSocket accepts extension offer without negotiating compression")
        check(scope.permitsPeer("192.168.1.1") && !scope.permitsPeer("8.8.8.8"), "only private peers")
        check(!BrowserAccessScope(address: "127.0.0.1", port: 7443, usesTLS: false).permitsPeer("192.168.1.1"), "pairing listener remains local")
        check(BrowserAccessInterface.isPrivate("10.0.0.1") && BrowserAccessInterface.isPrivate("172.31.0.1")
              && !BrowserAccessInterface.isPrivate("172.32.0.1") && !BrowserAccessInterface.isPrivate("0.0.0.0"), "private bind scope")
        let payload = Data("中文\u{1b}[31m".utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        let wire = Data([0x82, 0x80 | UInt8(payload.count)] + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        check(try BrowserAccessWebSocketFrame.next(in: wire)?.payload == payload, "masked Unicode/ANSI WebSocket bytes")
        check(try BrowserAccessWebSocketFrame.next(in: Data(wire.prefix(3))) == nil, "fragmented network reads")
        for invalid in [Data([0x82, 1, 0]), Data([0x02, 0x80, 0, 0, 0, 0]), Data([0xc2, 0x80, 0, 0, 0, 0]),
                        Data([0x82, 0xff]), Data([0x89, 0xfe, 0, 126])] {
            rejects({ _ = try BrowserAccessWebSocketFrame.next(in: invalid) }, "invalid WebSocket frame accepted")
        }
        var observer = PTYMuxObserverFrame.encode(kind: .resize, data: Data([0, 80, 0, 24]))
        observer.append(PTYMuxObserverFrame.encode(kind: .output, data: payload))
        let first = try PTYMuxObserverFrame.next(in: observer)!
        observer.removeFirst(first.consumed)
        check(try PTYMuxObserverFrame.next(in: observer)?.data == payload, "observer parser handles advanced Data indices")
        let certificate = try BrowserAccessCertificate.loadOrCreate(directory: root.appendingPathComponent("tls"), address: "192.168.0.10")
        let savedCertificate = try BrowserAccessCertificate.loadOrCreate(directory: root.appendingPathComponent("tls"), address: "192.168.0.10")
        check(certificate.fingerprint == savedCertificate.fingerprint && certificate.pem == savedCertificate.pem, "TLS identity is valid and reused")
        print("Browser access authorization, HTTP/WebSocket boundaries, observer frames, and generated TLS identity passed.")
    }
}
