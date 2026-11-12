import Darwin
import Foundation
import Network

@main
struct BrowserAccessNetworkHarness {
    @MainActor static func main() async throws {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let web = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let interfaces = await Self.interfaces()
        let requested = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "loopback"
        let interface = interfaces.first { $0.id == requested } ?? .loopback
        guard requested == "loopback" || interface.id == requested else {
            output(["type": "interfaces", "values": interfaces.map(\.id)])
            throw BrowserAccessError.message("Requested interface is unavailable.")
        }
        let port = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 7443 : 7443
        let certificate = interface.isLoopback ? nil : try BrowserAccessCertificate.loadOrCreate(
            directory: root.appendingPathComponent("tls"), address: interface.address)
        try PTYMuxCommandLine.startDaemonIfNeeded()
        try BrowserAccessMuxCapability.prepare()
        var sessionIDs: [UUID] = []
        for _ in 0..<2 {
            let create = try PTYMuxCommandLine.exchange(method: "create", params: [
                "workingDirectory": .string(root.path), "command": .array([.string("/bin/zsh"), .string("-f")]),
            ])
            sessionIDs.append(UUID(uuidString: create.result!.objectValue!["id"]!.stringValue!)!)
        }
        // Production sessions supply the current renderer theme. The standalone
        // probe supplies an ANSI palette so reconnect snapshots remain visible.
        var theme = ZshellTheme()
        theme.foreground = 0xeeeeee
        theme.background = 0x111318
        theme.cursor = 0xeeeeee
        withUnsafeMutableBytes(of: &theme.palette) { raw in
            let colors: [UInt32] = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
            let palette = raw.bindMemory(to: UInt32.self)
            for index in 0..<256 { palette[index] = colors[index % 16] }
        }
        let encodedTheme = withUnsafeBytes(of: &theme) { Data($0).base64EncodedString() }
        for sessionID in sessionIDs {
            _ = try PTYMuxCommandLine.exchange(method: "theme", params: ["id": .string(sessionID.uuidString), "theme": .string(encodedTheme)])
        }
        let visibleSessions = sessionIDs
        var assets: [String: (Data, String)] = [:]
        for file in ["index.html", "browser-access.js", "browser-access.css", "xterm.js", "xterm.css", "addon-fit.js", "addon-unicode11.js"] {
            assets[file == "index.html" ? "/" : "/" + file] = (try Data(contentsOf: web.appendingPathComponent(file)),
                file.hasSuffix(".html") ? "text/html; charset=utf-8" : file.hasSuffix(".css") ? "text/css" : "text/javascript")
        }
        let server = try BrowserAccessServer(directory: root.appendingPathComponent("authorization"), assets: assets,
            sessions: {
                visibleSessions.compactMap { sessionID in
                    guard let info = try? PTYMuxCommandLine.exchange(method: "get", params: ["id": .string(sessionID.uuidString)]).result,
                          info.objectValue?["running"]?.boolValue == true else { return nil }
                    return BrowserAccessSession(id: sessionID, project: "Fixture 中文", title: "zsh")
                }
            }, changed: { snapshot in
                if let local = snapshot.localURL {
                    output(["type": "endpoint", "url": local.absoluteString, "remoteURL": snapshot.remoteURL?.absoluteString ?? ""])
                }
                if !snapshot.pending.isEmpty {
                    output(["type": "pairings", "requests": snapshot.pending.map { ["id": $0.id.uuidString, "code": $0.code] }])
                }
            })
        try await server.start(interface: interface, port: port, certificate: certificate, translations: [:])
        // The network harness observes the same snapshot published to Settings.
        server.queue.sync {
            output(["type": "sessions", "ids": sessionIDs.map(\.uuidString)])
        }
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                Task { @MainActor in
                    let parts = line.split(separator: " ")
                    guard let command = parts.first else { return }
                    switch command {
                    case "approve":
                        if parts.count == 2, let id = UUID(uuidString: String(parts[1])) {
                            server.approve(id) { message in output(["type": "approved", "error": message ?? ""]) }
                        }
                    case "deny":
                        if parts.count == 2, let id = UUID(uuidString: String(parts[1])) {
                            server.deny(id)
                            server.queue.async { output(["type": "denied"]) }
                        }
                    case "revoke":
                        server.revoke(nil) { message in output(["type": "revoked", "error": message ?? ""]) }
                    case "stop": server.stop(); output(["type": "stopped"])
                    case "restart":
                        await server.stop().value
                        do {
                            try await server.start(interface: interface, port: port, certificate: certificate, translations: [:])
                            output(["type": "restarted"])
                        } catch { output(["type": "restartFailed", "error": error.localizedDescription]) }
                    case "terminate":
                        if parts.count == 2 {
                            _ = try? PTYMuxCommandLine.exchange(method: "terminate", params: ["id": .string(String(parts[1]))])
                            output(["type": "terminated", "id": String(parts[1])])
                        }
                    case "inspect":
                        if parts.count == 2,
                           let value = try? PTYMuxCommandLine.exchange(method: "get", params: [
                               "id": .string(String(parts[1])), "tailBytes": .number(65_536),
                           ]).result,
                           let data = try? JSONEncoder().encode(value),
                           let info = try? JSONSerialization.jsonObject(with: data) {
                            output(["type": "inspected", "info": info])
                        }
                    case "quit":
                        server.stop()
                        _ = try? PTYMuxCommandLine.exchange(method: "terminateAll")
                        try? await Task.sleep(for: .milliseconds(400))
                        _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
                        exit(0)
                    default: break
                    }
                }
            }
        }
        while true { try await Task.sleep(for: .seconds(30)) }
    }

    nonisolated static func output(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        FileHandle.standardOutput.write(data + Data([10]))
    }

    nonisolated static func interfaces() async -> [BrowserAccessInterface] {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: BrowserAccessInterface.available(on: path.availableInterfaces))
            }
            monitor.start(queue: DispatchQueue.global())
        }
    }
}
