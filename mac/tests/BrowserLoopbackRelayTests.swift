import Foundation
import Network
#if BROWSER_RELAY_BUILT_APP
    @testable import zshell
#endif

@main
struct BrowserLoopbackRelayTests {
    private final class WeakConnection {
        weak var value: NWConnection?
        init(_ value: NWConnection) { self.value = value }
    }

    @MainActor static func main() async {
        do { try await run() } catch { fputs("Relay test failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        let mode = CommandLine.arguments[1]
        let upstreamPort = UInt16(CommandLine.arguments[2])!
        let projectID = UUID(), browserID = UUID()
        let routing: BrowserRemoteRouting?
        if mode == "routing" {
            let endpoint = try SSHEndpoint(host: "127.0.0.1", port: Int(upstreamPort))
            routing = BrowserRemoteRouting(location: .ssh(endpoint: endpoint, remoteDirectory: nil), storageID: UUID())
        } else {
            routing = nil
        }
        var relay: BrowserLoopbackRelay?
        weak var observedRelay: BrowserLoopbackRelay?
        weak var observedListener: NWListener?
        weak var observedRegistry: AnyObject?
        var observedConnections: [WeakConnection] = []
        while let command = await Task.detached(operation: { readLine() }).value {
            switch command {
            case "connect":
                if let routing {
                    routing.retain(browserID, projectID: projectID)
                    routing.setAvailable(true, projectID: projectID)
                    try await routing.ensureConnected()
                    relay = owned(routing, name: "relay", as: BrowserLoopbackRelay.self)
                    guard let forward = owned(routing, name: "forward", as: OpenSSHDynamicForward.self),
                        let relay
                    else { throw failure("Routing did not publish the relay and SSH forward") }
                    emit("READY \(relay.port) \(forward.port) \(forward.processID)")
                } else {
                    relay = try await BrowserLoopbackRelay.start(upstreamPort: upstreamPort)
                    emit("READY \(relay!.port) \(upstreamPort)")
                }
                guard let relay else { throw failure("Relay owner missing") }
                observedRelay = relay
                observedListener = try listener(for: relay)
                if let registry = Mirror(reflecting: relay).children.first(where: { $0.label == "connections" })?.value {
                    observedRegistry = registry as AnyObject
                } else {
                    #if !BROWSER_RELAY_HISTORICAL
                        throw failure("Registry owner missing")
                    #endif
                }
            case "capture":
                observedConnections = try snapshot(relay).map(WeakConnection.init)
                emit("CAPTURED \(observedConnections.count)")
            case "check":
                emit(
                    "CHECK \(try snapshot(relay).count) \(observedConnections.filter { $0.value != nil }.count) \(observedRelay == nil ? 0 : 1) \(observedListener == nil ? 0 : 1) \(observedRegistry == nil ? 0 : 1)"
                )
            case "unavailable", "release":
                guard let routing else { throw failure("Routing caller required") }
                if command == "release" { routing.release(browserID) } else { routing.setAvailable(false, projectID: projectID) }
                relay = nil
                guard routing.localProxyPort == nil else { throw failure("Disconnect kept the SSH forward") }
                emit("CLOSED")
            case "close":
                relay?.close()
                emit("CLOSED")
            case "drop":
                relay = nil
                emit("DROPPED")
            #if BROWSER_RELAY_REGISTRY_TESTS
                case "delayed-start":
                    guard let relay else { throw failure("Relay required") }
                    observedConnections = try delayedStart(relay, upstreamPort: upstreamPort)
                    emit("DELAYED")
                case "pause-accept":
                    guard let relay else { throw failure("Relay required") }
                    relay.pauseAcceptForTest()
                    emit("PAUSING")
                case "resume-accept":
                    guard let relay else { throw failure("Relay required") }
                    relay.resumeAcceptForTest()
                    emit("RESUMED")
            #endif
            case "quit":
                relay?.close()
                routing?.release(browserID)
                return
            default: throw failure("Unknown command: \(command)")
            }
        }
        relay?.close()
        routing?.release(browserID)
    }

    @MainActor private static func owned<T>(_ owner: Any, name: String, as type: T.Type) -> T? {
        guard let property = Mirror(reflecting: owner).children.first(where: { $0.label == name }) else { return nil }
        return Mirror(reflecting: property.value).children.first?.value as? T
    }

    @MainActor private static func listener(for relay: BrowserLoopbackRelay) throws -> NWListener {
        guard let listener = Mirror(reflecting: relay).children.first(where: { $0.label == "listener" })?.value as? NWListener else {
            throw failure("Listener owner missing")
        }
        return listener
    }

    @MainActor private static func snapshot(_ relay: BrowserLoopbackRelay?) throws -> [NWConnection] {
        guard let relay else { return [] }
        guard let queue = try listener(for: relay).queue else { throw failure("Listener queue missing") }
        return try queue.sync { () throws -> [NWConnection] in
            guard let registry = Mirror(reflecting: relay).children.first(where: { $0.label == "connections" })?.value,
                let active = Mirror(reflecting: registry).children.first(where: { $0.label == "active" })?.value
                    as? [ObjectIdentifier: NWConnection]
            else {
                #if BROWSER_RELAY_HISTORICAL
                    return []
                #else
                    throw failure("Active connections missing")
                #endif
            }
            return Array(active.values)
        }
    }

    #if BROWSER_RELAY_REGISTRY_TESTS
        @MainActor private static func delayedStart(_ relay: BrowserLoopbackRelay, upstreamPort: UInt16) throws -> [WeakConnection] {
            let before = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
            let after = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
            let observed = [WeakConnection(before), WeakConnection(after)]
            precondition(relay.registerForTest(before))
            relay.close()
            precondition(!relay.registerForTest(after))
            after.cancel()
            guard let queue = try listener(for: relay).queue else { throw failure("Listener queue missing") }
            before.start(queue: queue)
            after.start(queue: queue)
            return observed
        }
    #endif

    private static func emit(_ value: String) { print(value); fflush(stdout) }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BrowserLoopbackRelayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
