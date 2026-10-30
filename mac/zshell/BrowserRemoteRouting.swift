import Combine
import Foundation
import Network
import WebKit

/// One project owns the origin namespace and SSH connection shared by its
/// browser panes. A separate data store keeps remote localhost cookies local
/// to that project, including when the layout is restored.
@MainActor
final class BrowserRemoteRouting: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected, unavailable
        case failed(String)
    }

    let dataStore: WKWebsiteDataStore
    private(set) var location: ProjectLocation
    @Published private(set) var state: State = .idle
    private var users: [UUID: UUID] = [:]
    private var projectAvailability: [UUID: Bool] = [:]
    @Published private(set) var loopbackRules: WKContentRuleList?
    private var forward: OpenSSHDynamicForward?
    private var relay: BrowserLoopbackRelay?
    private var connecting: Task<(OpenSSHDynamicForward, BrowserLoopbackRelay), Error>?
    private var generation: UInt = 0
    private var timer: Timer?
    private var faviconSession: URLSession?

    init(location: ProjectLocation, storageID: UUID) {
        self.location = location
        dataStore = WKWebsiteDataStore(forIdentifier: storageID)
        // Never fall through to the Mac's localhost while the SSH connection
        // is starting or unavailable. Port 1 is replaced after authentication.
        dataStore.proxyConfigurations = [Self.proxy(port: 1)]
    }

    deinit {
        timer?.invalidate()
        connecting?.cancel()
        forward?.close()
        relay?.close()
        faviconSession?.invalidateAndCancel()
    }

    var hostName: String {
        switch location {
        case .ssh(let endpoint, _, _, _): endpoint.destination
        case .shared(let host, _): host.name
        case .local: ""
        }
    }

    var localProxyPort: UInt16? { forward?.port }

    private var isAvailable: Bool {
        users.values.contains { projectAvailability[$0] ?? true }
    }

    /// CFNetwork connects localhost, 127.0.0.0/8 and ::1 directly even when a
    /// proxy is configured, so remote pages load them through a proxied
    /// *.localhost alias. Common dev servers accept *.localhost hosts.
    nonisolated static let aliasHost = "zshell-remote.localhost"

    static func isLoopback(_ url: URL) -> Bool {
        isDirectLoopback(url) || url.host?.lowercased().hasSuffix(".localhost") == true
    }

    nonisolated static func routedURL(_ url: URL) -> URL {
        guard isDirectLoopback(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = aliasHost
        return components.url ?? url
    }

    static func displayURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == aliasHost,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = "localhost"
        return components.url ?? url
    }

    nonisolated private static func isDirectLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")) else { return false }
        return host == "localhost" || host == "::1" || host == "0.0.0.0" || host.hasPrefix("::ffff:7f")
            || (host.hasPrefix("127.") && IPv4Address(host) != nil)
    }

    /// The alias is only the proxy's routing name; the page really talks to
    /// the remote host's loopback, so a dev certificate is checked against the
    /// loopback names the alias stands in for. Evaluation can block, so it
    /// runs off the main thread and reports back on it.
    nonisolated static func evaluateLoopbackTrust(
        _ challenge: URLAuthenticationChallenge,
        completion: @escaping @MainActor @Sendable (URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host.lowercased() == aliasHost, let trust = space.serverTrust else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        nonisolated(unsafe) let unsafeTrust = trust
        DispatchQueue.global(qos: .userInitiated).async {
            var credential: URLCredential?
            for name in ["localhost", "127.0.0.1", "::1"] {
                SecTrustSetPolicies(unsafeTrust, SecPolicyCreateSSL(true, name as CFString))
                if SecTrustEvaluateWithError(unsafeTrust, nil) {
                    credential = URLCredential(trust: unsafeTrust)
                    break
                }
            }
            let result = credential
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Fail closed for loopback URLs that page scripts or redirects produce
    /// outside the bridge below.
    private static let loopbackRuleSource = #"""
    [{"trigger":{"url-filter":"^[a-z]+://localhost\\.?[:/]"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^[a-z]+://127\\."},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^[a-z]+://0\\.0\\.0\\.0[:/]"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^[a-z]+://\\[::1\\]"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^[a-z]+://\\[::ffff:7f"},"action":{"type":"block"}}]
    """#

    static let bridgeScript = """
    (() => {
      const alias = '\(aliasHost)';
      const direct = host => host === 'localhost' || host === 'localhost.' || host === '[::1]' || host === '0.0.0.0'
        || host.startsWith('[::ffff:7f') || /^127\\.\\d+\\.\\d+\\.\\d+$/.test(host);
      const route = value => {
        try {
          const url = new URL(String(value), document.baseURI);
          if (!direct(url.hostname)) return value;
          url.hostname = alias;
          return url.href;
        } catch { return value; }
      };
      const wrap = (name, Native) => {
        if (!Native) return;
        const Routed = function (url, ...rest) { return new Native(route(url), ...rest); };
        Routed.prototype = Native.prototype;
        Object.setPrototypeOf(Routed, Native);
        window[name] = Routed;
      };
      wrap('WebSocket', window.WebSocket);
      wrap('EventSource', window.EventSource);
      const fetch = window.fetch;
      window.fetch = function (input, init) {
        return fetch.call(this, input instanceof Request ? new Request(route(input.url), input) : route(input), init);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url, ...rest) { return open.call(this, method, route(url), ...rest); };
      const attributes = { SCRIPT: 'src', IMG: 'src', IFRAME: 'src', LINK: 'href', SOURCE: 'src', VIDEO: 'src', AUDIO: 'src', EMBED: 'src' };
      // Script and media elements start fetching as soon as they are inserted
      // or assigned, before a MutationObserver runs, so route the value as it
      // is written.
      const routedProperties = [['HTMLScriptElement', 'src'], ['HTMLImageElement', 'src'], ['HTMLIFrameElement', 'src'],
        ['HTMLLinkElement', 'href'], ['HTMLSourceElement', 'src'], ['HTMLMediaElement', 'src'], ['HTMLEmbedElement', 'src']];
      for (const [type, name] of routedProperties) {
        const prototype = window[type] && window[type].prototype;
        const descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, name);
        if (!descriptor || !descriptor.set) continue;
        Object.defineProperty(prototype, name, { ...descriptor, set(value) { descriptor.set.call(this, route(value)); } });
      }
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        const routes = attributes[this.tagName] === String(name).toLowerCase();
        return setAttribute.call(this, name, routes ? route(value) : value);
      };
      const patch = node => {
        const name = attributes[node.tagName];
        const value = name && node.getAttribute(name);
        if (value && route(value) !== value) node.setAttribute(name, route(value));
      };
      new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes') { patch(record.target); continue; }
          for (const node of record.addedNodes) {
            if (node.nodeType !== 1) continue;
            patch(node);
            node.querySelectorAll('[src],link[href]').forEach(patch);
          }
        }
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'href'] });
    })();
    """

    func retain(_ id: UUID, projectID: UUID) {
        users[id] = projectID
        if isAvailable, state == .unavailable { disconnect(to: .idle) }
    }

    func release(_ id: UUID) {
        users.removeValue(forKey: id)
        if users.isEmpty { disconnect(to: .idle) }
        else if !isAvailable { disconnect(to: .unavailable) }
    }

    func update(location: ProjectLocation) {
        guard self.location != location else { return }
        self.location = location
        disconnect(to: isAvailable ? .idle : .unavailable)
    }

    func setAvailable(_ available: Bool, projectID: UUID) {
        let before = isAvailable
        projectAvailability[projectID] = available
        guard before != isAvailable else { return }
        disconnect(to: isAvailable ? .idle : .unavailable)
    }

    func ensureConnected() async throws {
        guard isAvailable, !users.isEmpty else {
            throw RemoteHostError.message(String(localized: "Reconnect the remote session to preview localhost."))
        }
        if loopbackRules == nil {
            loopbackRules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "zshell-remote-loopback", encodedContentRuleList: Self.loopbackRuleSource
            )
        }
        if let forward, forward.isRunning { return }
        if connecting == nil {
            let location = location
            state = .connecting
            connecting = Task.detached(priority: .userInitiated) {
                let endpoint: SSHEndpoint
                let authentication: SSHAuthentication
                let credentialID: UUID?
                switch location {
                case .ssh(let ssh, _, let auth, let credential):
                    endpoint = ssh; authentication = auth; credentialID = credential
                case .shared(let host, _):
                    switch try host.endpoint() {
                    case .ssh(let ssh): endpoint = ssh
                    case .tailscale(let hostname, _): endpoint = try SSHEndpoint(host: hostname)
                    }
                    authentication = .agent; credentialID = nil
                case .local:
                    throw CancellationError()
                }
                let forward = try OpenSSHTransport().startDynamicForwarding(
                    endpoint: endpoint, authentication: authentication, credentialID: credentialID
                )
                do {
                    return (forward, try await BrowserLoopbackRelay.start(upstreamPort: forward.port))
                } catch {
                    forward.close()
                    throw error
                }
            }
        }
        let revision = generation
        guard let pending = connecting else { throw CancellationError() }
        do {
            let (tunnel, tunnelRelay) = try await pending.value
            guard revision == generation, isAvailable, !users.isEmpty else {
                tunnel.close()
                tunnelRelay.close()
                throw CancellationError()
            }
            // Multiple panes can await the same connection; publish only once.
            if forward !== tunnel {
                forward?.close()
                relay?.close()
                forward = tunnel
                relay = tunnelRelay
                dataStore.proxyConfigurations = [Self.proxy(port: tunnelRelay.port)]
                faviconSession?.invalidateAndCancel()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.proxyConfigurations = dataStore.proxyConfigurations
                faviconSession = URLSession(configuration: configuration)
                state = .connected
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    assumeMainActor {
                        guard let self, let forward = self.forward, !forward.isRunning else { return }
                        self.disconnect(to: self.isAvailable ? .idle : .unavailable)
                    }
                }
            }
            connecting = nil
        } catch {
            guard revision == generation else { throw CancellationError() }
            connecting = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func faviconData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await ensureConnected()
        guard let faviconSession else { throw CancellationError() }
        var request = request
        request.url = request.url.map(Self.routedURL)
        return try await faviconSession.data(for: request, delegate: FaviconRedirects())
    }

    private func disconnect(to state: State) {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        connecting?.cancel()
        connecting = nil
        forward?.close()
        forward = nil
        relay?.close()
        relay = nil
        faviconSession?.invalidateAndCancel()
        faviconSession = nil
        dataStore.proxyConfigurations = [Self.proxy(port: 1)]
        self.state = state
    }

    private static func proxy(port: UInt16) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.matchDomains = ["localhost"]
        proxy.allowFailover = false
        return proxy
    }
}

/// URLSession follows favicon redirects itself, outside WebKit's content
/// rules, so a remote page could otherwise redirect it to the Mac's localhost.
nonisolated private final class FaviconRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        request.url = request.url.map(BrowserRemoteRouting.routedURL)
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        BrowserRemoteRouting.evaluateLoopbackTrust(challenge) { credential in
            completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
        }
    }
}

/// SOCKS5 front for `ssh -D`. It only accepts *.localhost names and connects
/// them to the remote host's own localhost, which may not resolve aliases.
nonisolated final class BrowserLoopbackRelay: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(upstreamPort: UInt16) async throws -> BrowserLoopbackRelay {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "zshell.browser-loopback-relay")
        let upstream = NWEndpoint.Port(rawValue: upstreamPort)!
        listener.newConnectionHandler = { serve($0, upstream: upstream, queue: queue) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return BrowserLoopbackRelay(listener: listener, port: port)
    }

    func close() {
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    private static func serve(_ client: NWConnection, upstream: NWEndpoint.Port, queue: DispatchQueue) {
        client.start(queue: queue)
        let refuse = { client.send(content: Data([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in client.cancel() }) }
        read(client, 2) { greeting in
            guard let greeting, greeting[0] == 5 else { return client.cancel() }
            read(client, Int(greeting[1])) { methods in
                guard methods?.contains(0) == true else { return client.cancel() }
                client.send(content: Data([5, 0]), completion: .idempotent)
                read(client, 5) { head in
                    guard let head, head[0] == 5, head[1] == 1, head[3] == 3 else { return refuse() }
                    read(client, Int(head[4]) + 2) { tail in
                        guard let tail else { return client.cancel() }
                        let name = String(decoding: tail.dropLast(2), as: UTF8.self).lowercased()
                        guard name == "localhost" || name.hasSuffix(".localhost") else { return refuse() }
                        let remote = NWConnection(host: "127.0.0.1", port: upstream, using: .tcp)
                        remote.start(queue: queue)
                        remote.send(content: Data([5, 1, 0]), completion: .idempotent)
                        read(remote, 2) { choice in
                            guard choice == [5, 0] else { remote.cancel(); return refuse() }
                            remote.send(content: Data([5, 1, 0, 3, 9]) + Data("localhost".utf8) + Data(tail.suffix(2)), completion: .idempotent)
                            let pair = Pair(client, remote)
                            pipe(client, to: remote, pair: pair)
                            pipe(remote, to: client, pair: pair)
                        }
                    }
                }
            }
        }
    }

    private final class Pair: @unchecked Sendable {
        private let connections: [NWConnection]
        private var open = 2

        init(_ first: NWConnection, _ second: NWConnection) { connections = [first, second] }

        func finish(failed: Bool) {
            open -= 1
            if failed || open == 0 { connections.forEach { $0.cancel() } }
        }
    }

    private static func pipe(_ source: NWConnection, to destination: NWConnection, pair: Pair) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            guard error == nil else { return pair.finish(failed: true) }
            destination.send(content: data, contentContext: isComplete ? .finalMessage : .defaultMessage,
                             isComplete: isComplete, completion: .contentProcessed { sendError in
                if sendError != nil { pair.finish(failed: true) }
                else if isComplete { pair.finish(failed: false) }
                else { pipe(source, to: destination, pair: pair) }
            })
        }
    }

    private static func read(_ connection: NWConnection, _ count: Int, _ next: @escaping @Sendable ([UInt8]?) -> Void) {
        guard count > 0 else { return next([]) }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            next(error == nil && data?.count == count ? data.map(Array.init) : nil)
        }
    }
}
