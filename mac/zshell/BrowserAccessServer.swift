import Foundation
import Network

nonisolated struct BrowserAccessSession: Codable, Equatable, Sendable {
    let id: UUID
    let project: String
    let title: String
}

nonisolated struct BrowserAccessPendingClient: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let address: String
    let origin: String
    let code: String
}

nonisolated struct BrowserAccessServerSnapshot: Sendable {
    let revision: UInt64
    let localURL: URL?
    let remoteURL: URL?
    let fingerprint: String?
    let certificate: Data?
    let clients: [BrowserAccessClient]
    let pending: [BrowserAccessPendingClient]
}

nonisolated final class BrowserAccessServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "sh.zshell.browser-access.server", qos: .userInitiated)
    private let authorization: BrowserAccessAuthorization
    private let assets: [String: (data: Data, type: String)]
    private let sessions: @MainActor @Sendable () -> [BrowserAccessSession]
    private let changed: @Sendable (BrowserAccessServerSnapshot) -> Void
    private var connections: [UUID: BrowserAccessConnection] = [:]
    private var listeners: [NWListener] = []
    private var cancellingListeners = Set<ObjectIdentifier>()
    private let listenerCancellation = DispatchGroup()
    private var running = false
    private var localScope: BrowserAccessScope?
    private var remoteScope: BrowserAccessScope?
    private var certificate: BrowserAccessCertificate?
    private var refreshTimer: DispatchSourceTimer?
    private var refreshing = false
    private var lastSessions: [BrowserAccessSession] = []
    private var translations: [String: String] = [:]
    private var revision: UInt64 = 0

    init(directory: URL, assets: [String: (Data, String)],
         sessions: @escaping @MainActor @Sendable () -> [BrowserAccessSession],
         changed: @escaping @Sendable (BrowserAccessServerSnapshot) -> Void) throws {
        authorization = try BrowserAccessAuthorization(directory: directory)
        self.assets = assets
        self.sessions = sessions
        self.changed = changed
    }

    func start(interface: BrowserAccessInterface, port: Int, certificate: BrowserAccessCertificate?,
               translations: [String: String]) async throws {
        await waitForListenerCancellation()
        queue.sync { running = true; self.certificate = certificate; self.translations = translations }
        do {
            let localPorts = BrowserAccessConfiguration.localPorts(for: port)
            for (index, port) in localPorts.enumerated() {
                do {
                    let local = NWParameters.tcp
                    local.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                    // Rebind after our own TCP connections enter TIME_WAIT;
                    // a second live listener still fails with EADDRINUSE.
                    local.allowLocalEndpointReuse = true
                    try await start(NWListener(using: local), address: "127.0.0.1", tls: false)
                    break
                } catch NWError.posix(.EADDRINUSE) where index + 1 < localPorts.count {
                    await waitForListenerCancellation()
                    continue
                }
            }
            if !interface.isLoopback {
                guard let certificate else { throw BrowserAccessHTTPRequest.invalid }
                let listener = try NWListener(using: certificate.parameters(interface: interface), on: NWEndpoint.Port(rawValue: UInt16(port))!)
                try await start(listener, address: interface.address, tls: true)
            }
            queue.sync {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .seconds(2))
                timer.setEventHandler { [weak self] in self?.refresh() }
                refreshTimer = timer
                timer.resume()
                publish()
            }
        } catch { stop(); throw error }
    }

    private func start(_ listener: NWListener, address: String, tls: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard running else { continuation.resume(throwing: CancellationError()); return }
                listeners.append(listener)
                var resumed = false
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self,
                          let scope = tls ? remoteScope : localScope, running else { connection.cancel(); return }
                    accept(connection, scope: scope)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !resumed, let port = listener.port?.rawValue, port != 0 else { return }
                        resumed = true
                        let scope = BrowserAccessScope(address: address, port: port, usesTLS: tls)
                        if tls { remoteScope = scope } else { localScope = scope }
                        continuation.resume()
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            listeners.removeAll { $0 === listener }
                            cancel(listener)
                            continuation.resume(throwing: error)
                        } else { shutdown() }
                    case .cancelled:
                        if cancellingListeners.remove(ObjectIdentifier(listener)) != nil { listenerCancellation.leave() }
                        listener.stateUpdateHandler = nil
                        if !resumed { resumed = true; continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }
    }

    @discardableResult func stop() -> Task<Void, Never> {
        queue.sync { shutdown() }
        return Task { await waitForListenerCancellation() }
    }

    private func cancel(_ listener: NWListener) {
        if cancellingListeners.insert(ObjectIdentifier(listener)).inserted { listenerCancellation.enter() }
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    private func waitForListenerCancellation() async {
        await withCheckedContinuation { continuation in
            listenerCancellation.notify(queue: queue) { continuation.resume() }
        }
    }

    private func shutdown() {
        running = false
        listeners.forEach(cancel)
        listeners.removeAll()
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
        refreshTimer?.cancel()
        refreshTimer = nil
        authorization.clearPending()
        localScope = nil
        remoteScope = nil
        publish()
    }

    func updateTranslations(_ values: [String: String]) {
        queue.async { [self] in translations = values }
    }

    func approve(_ id: UUID, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard running else { completion(nil); return }
            do { try authorization.approve(id); publish(); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }

    func deny(_ id: UUID) { queue.async { [self] in authorization.deny(id); publish() } }

    func revoke(_ id: UUID?, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            // Revoke before disk IO, and close sockets even when saving fails.
            let result: String?
            do {
                if let id { try authorization.revoke(id) } else { try authorization.revokeAll() }
                result = nil
            } catch { result = error.localizedDescription }
            for connection in Array(connections.values) where id == nil || connection.clientID == id { connection.close() }
            publish()
            completion(result)
        }
    }

    private func accept(_ transport: NWConnection, scope: BrowserAccessScope) {
        guard running, connections.count < BrowserAccessLimits.connections,
              case .hostPort(let host, _) = transport.endpoint,
              case .ipv4(let address) = host else { transport.cancel(); return }
        let peer = address.rawValue.map(String.init).joined(separator: ".")
        guard scope.permitsPeer(peer) else { transport.cancel(); return }
        let connection = BrowserAccessConnection(transport: transport, server: self, scope: scope, peer: peer)
        connections[connection.id] = connection
        connection.start()
    }

    fileprivate func removed(_ id: UUID) { connections.removeValue(forKey: id) }

    fileprivate func route(_ request: BrowserAccessHTTPRequest, connection: BrowserAccessConnection) {
        guard running else { connection.close(); return }
        if request.method == "GET", let asset = assets[request.path] {
            connection.respond(status: 200, type: asset.type, data: asset.data)
        } else if request.method == "GET", request.path == "/api/info" {
            connection.respondJSON([
                "remoteURL": remoteScope?.origin ?? "", "fingerprint": certificate?.fingerprint ?? "",
                "strings": translations, "local": !connection.scope.usesTLS,
                "language": AppLocalization.current.identifier,
            ])
        } else if request.method == "GET", request.path == "/certificate.pem", let certificate {
            connection.respond(status: 200, type: "application/x-pem-file", data: certificate.pem)
        } else if request.method == "GET", request.path == "/favicon.ico" {
            connection.respond(status: 204, type: "image/x-icon", data: Data())
        } else if request.method == "POST", request.path == "/api/pair" {
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body),
                  body.count == 1, let name = body["name"] else { connection.reject(); return }
            do {
                let pairing = try authorization.begin(name: name, address: connection.peer, origin: connection.scope.origin)
                connection.respondJSON(["ticket": pairing.ticket, "code": pairing.code])
                publish()
            } catch { connection.respondJSON(["error": error.localizedDescription], status: 429) }
        } else if request.method == "POST", request.path == "/api/pair/status" {
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body),
                  body.count == 1, let ticket = body["ticket"] else { connection.reject(); return }
            let result = authorization.status(ticket: ticket, address: connection.peer, origin: connection.scope.origin)
            connection.respondJSON(["state": result.state, "token": result.token ?? ""])
            publish()
        } else if request.method == "GET", request.path == "/terminal" {
            guard connections.values.filter(\.isWebSocket).count < BrowserAccessLimits.webSockets,
                  let accept = try? request.webSocketAccept() else { connection.reject(); return }
            connection.upgrade(accept: accept)
        } else { connection.respond(status: 404, type: "text/plain; charset=utf-8", data: Data("Not found".utf8)) }
    }

    fileprivate func authenticate(_ token: String, connection: BrowserAccessConnection) -> BrowserAccessClient? {
        guard running, authorization.allowAttempt(connection.peer),
              let client = authorization.authenticate(token: token, origin: connection.scope.origin),
              connections.values.filter({ $0.clientID == client.id }).count < BrowserAccessLimits.socketsPerClient else { return nil }
        return client
    }

    fileprivate func isAuthorized(_ connection: BrowserAccessConnection) -> Bool {
        running && connection.clientID.map { authorization.isAuthorized($0, origin: connection.scope.origin) } == true
    }

    fileprivate func select(session id: UUID, connection: BrowserAccessConnection, generation: UUID) {
        let provider = sessions
        Task { @MainActor [weak connection, weak self] in
            let available = provider().contains { $0.id == id }
            guard let self else { return }
            queue.async { [weak connection, weak self] in
                guard let self, let connection, connection.generation == generation,
                      !connection.isClosed, isAuthorized(connection) else { return }
                guard available else { connection.sendJSON(["type": "unavailable"]); return }
                connection.attach(id)
            }
        }
    }

    fileprivate func resize(session id: UUID, columns: Int, rows: Int, connection: BrowserAccessConnection) {
        guard isAuthorized(connection), connection.sessionID == id else { connection.close(); return }
        // Control work stays off the network queue. Disable closes the browser
        // immediately; the in-flight bounded resize is harmless to PTY input.
        DispatchQueue.global(qos: .utility).async {
            _ = try? PTYMuxCommandLine.exchange(method: "resize", params: [
                "id": .string(id.uuidString), "columns": .number(Double(columns)), "rows": .number(Double(rows)),
                "cellWidth": .number(8), "cellHeight": .number(16),
            ], timeout: 0.2)
        }
    }

    fileprivate func sendSessions(to connection: BrowserAccessConnection) {
        guard isAuthorized(connection) else { connection.close(); return }
        if let payload = try? JSONEncoder().encode(lastSessions),
           let values = try? JSONSerialization.jsonObject(with: payload) {
            connection.sendJSON(["type": "sessions", "sessions": values])
        }
        refresh()
    }

    private func refresh() {
        guard running, !refreshing else { return }
        authorization.expire()
        publish()
        for connection in Array(connections.values) where connection.clientID != nil && !isAuthorized(connection) { connection.close() }
        guard connections.values.contains(where: { $0.clientID != nil }) else { return }
        refreshing = true
        let provider = sessions
        Task { @MainActor [weak self] in
            let current = provider()
            guard let self else { return }
            queue.async { [weak self] in
                guard let self else { return }
                refreshing = false
                guard running else { return }
                if current != lastSessions {
                    lastSessions = current
                    for connection in Array(connections.values) where connection.clientID != nil { sendSessions(to: connection) }
                }
                let ids = Set(current.map(\.id))
                for connection in Array(connections.values) {
                    if let id = connection.sessionID, !ids.contains(id) { connection.detach(); connection.sendJSON(["type": "unavailable"]) }
                }
            }
        }
    }

    private func publish() {
        revision &+= 1
        changed(BrowserAccessServerSnapshot(revision: revision, localURL: localScope?.url, remoteURL: remoteScope?.url,
            fingerprint: certificate?.fingerprint, certificate: certificate?.pem, clients: authorization.clients,
            pending: authorization.pairings.filter { $0.state == .pending }.map {
                BrowserAccessPendingClient(id: $0.id, name: $0.name, address: $0.address, origin: $0.origin, code: $0.code)
            }))
    }
}

nonisolated final class BrowserAccessConnection: @unchecked Sendable {
    let id = UUID()
    let scope: BrowserAccessScope
    let peer: String
    private let transport: NWConnection
    private weak var server: BrowserAccessServer?
    private var buffer = Data()
    private var sendQueue: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var isReading = false
    private var hasRequest = false
    private(set) var isWebSocket = false
    private(set) var isClosed = false
    private(set) var clientID: UUID?
    private var bridge: BrowserAccessMuxBridge?
    private var ready = false
    private var receivedPong = true
    private var messages = 0
    private var messageWindow = Date()
    private var resizing = false
    private var selections = 0
    private var deadline: DispatchSourceTimer?
    private(set) var generation = UUID()
    var sessionID: UUID? { bridge?.sessionID }

    init(transport: NWConnection, server: BrowserAccessServer, scope: BrowserAccessScope, peer: String) {
        self.transport = transport
        self.server = server
        self.scope = scope
        self.peer = peer
    }

    func start() {
        guard let server else { return }
        transport.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.read()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: server.queue)
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard clientID != nil, isWebSocket, receivedPong else { close(); return }
            receivedPong = false
            enqueue(BrowserAccessWebSocketFrame.encode(opcode: 9, payload: Data()))
        }
        deadline = timer
        timer.resume()
        transport.start(queue: server.queue)
    }

    private func read() {
        guard !isClosed, !isReading else { return }
        isReading = true
        transport.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            isReading = false
            guard !isClosed, error == nil, !complete, let data, !data.isEmpty,
                  buffer.count + data.count <= BrowserAccessLimits.headerBytes + BrowserAccessLimits.frameBytes + 8 else { close(); return }
            buffer.append(data)
            process()
            if !hasRequest || isWebSocket { read() }
        }
    }

    private func process() {
        do {
            if !hasRequest {
                guard let (request, consumed) = try BrowserAccessHTTPRequest.next(in: buffer, scope: scope) else { return }
                buffer.removeFirst(consumed)
                guard buffer.isEmpty else { reject(); return }
                hasRequest = true
                server?.route(request, connection: self)
            } else if isWebSocket {
                while let frame = try BrowserAccessWebSocketFrame.next(in: buffer) {
                    buffer.removeFirst(frame.consumed)
                    guard handle(frame) else { close(); return }
                }
            }
        } catch { reject() }
    }

    private func handle(_ frame: BrowserAccessWebSocketFrame.Frame) -> Bool {
        guard let server else { return false }
        if frame.opcode == 8 { return false }
        if frame.opcode == 9 { enqueue(BrowserAccessWebSocketFrame.encode(opcode: 10, payload: frame.payload)); return true }
        if frame.opcode == 10 { receivedPong = true; return true }
        if Date().timeIntervalSince(messageWindow) >= 1 { messages = 0; selections = 0; messageWindow = Date() }
        messages += 1
        guard messages <= 500 else { return false }
        if clientID == nil {
            guard frame.opcode == 1,
                  let value = try? JSONDecoder().decode([String: String].self, from: frame.payload),
                  value.count == 2, value["type"] == "authenticate", let token = value["token"],
                  let client = server.authenticate(token, connection: self) else { return false }
            clientID = client.id
            sendJSON(["type": "authenticated", "name": client.name])
            server.sendSessions(to: self)
            return true
        }
        guard server.isAuthorized(self) else { return false }
        if frame.opcode == 2 { return ready && bridge?.write(frame.payload) == true }
        guard frame.opcode == 1,
              let message = try? JSONDecoder().decode([String: ZshellJSONValue].self, from: frame.payload),
              let type = message["type"]?.stringValue else { return false }
        switch type {
        case "select":
            guard message.count == 2, let value = message["session"]?.stringValue, let session = UUID(uuidString: value) else { return false }
            selections += 1
            guard selections <= 8 else { return false }
            detach()
            server.select(session: session, connection: self, generation: generation)
        case "ack":
            guard message.count == 3, let count = message["bytes"]?.intValue,
                  (1...BrowserAccessLimits.outputCredit).contains(count),
                  let stream = message["stream"]?.stringValue, UUID(uuidString: stream) != nil else { return false }
            if stream == generation.uuidString, bridge?.acknowledge(count) != true { return false }
        case "resize":
            guard ready, message.count == 3, let columns = message["columns"]?.intValue,
                  let rows = message["rows"]?.intValue, let sessionID,
                  (1...512).contains(columns), (1...256).contains(rows), columns * rows <= 65_536 else { return false }
            if !resizing {
                resizing = true
                server.resize(session: sessionID, columns: columns, rows: rows, connection: self)
                server.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in self?.resizing = false }
            }
        default: return false
        }
        return true
    }

    func attach(_ id: UUID) {
        guard let server, server.isAuthorized(self), !isClosed else { return }
        let generation = generation
        let bridge = BrowserAccessMuxBridge(sessionID: id)
        self.bridge = bridge
        bridge.start(queue: server.queue, frame: { [weak self, weak bridge] kind, bytes in
            guard let self, let bridge, self.bridge === bridge, self.generation == generation,
                  self.server?.isAuthorized(self) == true, !isClosed else { return }
            switch kind {
            case .output: enqueue(BrowserAccessWebSocketFrame.encode(opcode: 2, payload: bytes))
            case .reset, .resize:
                guard bytes.count == 4 else { close(); return }
                let values = Array(bytes)
                sendJSON(["type": kind == .reset ? "reset" : "size", "session": id.uuidString,
                          "stream": generation.uuidString,
                          "columns": Int(values[0]) * 256 + Int(values[1]), "rows": Int(values[2]) * 256 + Int(values[3])])
            case .ready:
                ready = true
                sendJSON(["type": "ready", "session": id.uuidString])
            }
        }, ended: { [weak self, weak bridge] stalled in
            guard let self, let bridge, self.bridge === bridge, self.generation == generation, !isClosed else { return }
            if stalled { close(); return }
            detach()
            sendJSON(["type": "unavailable"])
        })
    }

    func detach() {
        generation = UUID()
        bridge?.close()
        bridge = nil
        ready = false
    }

    func upgrade(accept: String) {
        isWebSocket = true
        enqueue(Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: " + accept + "\r\n\r\n").utf8))
    }

    func respondJSON(_ value: [String: Any], status: Int = 200) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { close(); return }
        respond(status: status, type: "application/json; charset=utf-8", data: data)
    }

    func respond(status: Int, type: String, data: Data) {
        let reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 404 ? "Not Found" : status == 429 ? "Too Many Requests" : "Bad Request"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + "Referrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\n"
            + "X-Frame-Options: DENY\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            + "connect-src 'self'; font-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        transport.send(content: Data(headers.utf8) + data, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func reject() {
        if isWebSocket { close() }
        else { respond(status: 400, type: "text/plain; charset=utf-8", data: Data("Bad request".utf8)) }
    }

    func sendJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count < 65_536 else { close(); return }
        enqueue(BrowserAccessWebSocketFrame.encode(opcode: 1, payload: data))
    }

    private func enqueue(_ data: Data) {
        guard !isClosed, queuedBytes + data.count <= BrowserAccessLimits.sendQueueBytes else { close(); return }
        queuedBytes += data.count
        sendQueue.append(data)
        flush()
    }

    private func flush() {
        guard !isClosed, !sending, !sendQueue.isEmpty else { return }
        sending = true
        let data = sendQueue.removeFirst()
        transport.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            sending = false
            queuedBytes -= data.count
            if error != nil { close() } else { flush() }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        detach()
        deadline?.cancel()
        deadline = nil
        sendQueue.removeAll()
        transport.stateUpdateHandler = nil
        transport.cancel()
        server?.removed(id)
    }
}
