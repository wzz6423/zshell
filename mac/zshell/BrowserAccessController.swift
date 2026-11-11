import AppKit
import Combine
import Network

@MainActor
final class BrowserAccessController: nonisolated ObservableObject {
    static let shared = BrowserAccessController()

    @Published private(set) var interfaces: [BrowserAccessInterface] = [.loopback]
    @Published private(set) var localURL: URL?
    @Published private(set) var remoteURL: URL?
    @Published private(set) var fingerprint: String?
    @Published private(set) var certificate: Data?
    @Published private(set) var clients: [BrowserAccessClient] = []
    @Published private(set) var pending: [BrowserAccessPendingClient] = []
    @Published private(set) var error: String?
    @Published private(set) var isStarting = false
    private var server: BrowserAccessServer?
    private var startTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var networkMonitor: NWPathMonitor?
    private var workspaceObservations: [NSObjectProtocol] = []
    private var localizationObservation: NSObjectProtocol?
    private var requested: BrowserAccessConfiguration?
    private var generation = UUID()
    private var isRunning = false
    private var isSleeping = false
    private let directory = AppSettings.configURL.deletingLastPathComponent().appendingPathComponent("browser-access", isDirectory: true)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = BrowserAccessInterface.available(on: path.availableInterfaces)
            Task { @MainActor [weak self] in
                guard let self, isRunning else { return }
                if interfaces != available { interfaces = available }
                reconcile()
            }
        }
        monitor.start(queue: DispatchQueue(label: "sh.zshell.browser-access.interfaces", qos: .utility))
        settingsObservation = Publishers.CombineLatest3(AppSettings.shared.$browserAccessEnabled.removeDuplicates(),
            AppSettings.shared.$browserAccessInterface.removeDuplicates(), AppSettings.shared.$browserAccessPort.removeDuplicates())
            .sink { [weak self] enabled, interface, port in
                guard let self else { return }
                requested = BrowserAccessConfiguration(enabled: enabled, interfaceID: interface, port: port)
                reconcile(force: true)
            }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.isSleeping = note.name == NSWorkspace.willSleepNotification
                    self?.reconcile(force: true)
                }
            })
        }
        localizationObservation = NotificationCenter.default.addObserver(forName: AppLocalization.didChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.server?.updateTranslations(Self.translations()) }
            }
    }

    func stop() {
        isRunning = false
        settingsObservation = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        workspaceObservations.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservations.removeAll()
        if let localizationObservation { NotificationCenter.default.removeObserver(localizationObservation) }
        localizationObservation = nil
        stopServer()
    }

    func retry() { reconcile(force: true) }

    private func stopServer() {
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        server?.stop()
        server = nil
        isStarting = false
        localURL = nil
        remoteURL = nil
        pending = []
    }

    private func reconcile(force: Bool = false) {
        guard let requested else { return }
        if force { stopServer(); error = nil }
        guard isRunning, requested.enabled, !isSleeping else { stopServer(); return }
        guard let interface = interfaces.first(where: { $0.id == requested.interfaceID }) else {
            stopServer()
            error = String(localized: "Choose an available private network interface.")
            return
        }
        guard server == nil, startTask == nil else { return }
        error = nil
        isStarting = true
        let token = generation
        let directory = directory
        let translations = Self.translations()
        startTask = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try BrowserAccessMuxCapability.prepare()
                    let certificate = interface.isLoopback ? nil : try BrowserAccessCertificate.loadOrCreate(
                        directory: directory, address: interface.address)
                    let assets = try Self.assets()
                    return (certificate, assets)
                }.value
                guard let self, isRunning, generation == token, !Task.isCancelled else { return }
                let server = try BrowserAccessServer(directory: directory, assets: prepared.1,
                    sessions: { Self.sessions() }, changed: { [weak self] snapshot in
                        Task { @MainActor [weak self] in
                            guard let self, generation == token else { return }
                            apply(snapshot)
                        }
                    })
                self.server = server
                try await server.start(interface: interface, port: requested.port,
                                       certificate: prepared.0, translations: translations)
                guard generation == token else { server.stop(); return }
                isStarting = false
                startTask = nil
            } catch {
                guard let self, generation == token else { return }
                stopServer()
                if case BrowserAccessError.sessionServiceRequired = error {
                    AppSettings.shared.browserAccessEnabled = false
                }
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: BrowserAccessServerSnapshot) {
        if localURL != snapshot.localURL { localURL = snapshot.localURL }
        if remoteURL != snapshot.remoteURL { remoteURL = snapshot.remoteURL }
        if fingerprint != snapshot.fingerprint { fingerprint = snapshot.fingerprint }
        if certificate != snapshot.certificate { certificate = snapshot.certificate }
        if clients != snapshot.clients { clients = snapshot.clients }
        if pending != snapshot.pending { pending = snapshot.pending }
    }

    func approve(_ id: UUID) {
        server?.approve(id) { [weak self] message in
            Task { @MainActor [weak self] in self?.error = message }
        }
    }

    func deny(_ id: UUID) { server?.deny(id) }

    func revoke(_ id: UUID?) {
        if let server {
            server.revoke(id) { [weak self] message in
                Task { @MainActor [weak self] in self?.error = message }
            }
        } else {
            let directory = directory
            Task { [weak self] in
                do {
                    let clients = try await Task.detached(priority: .utility) {
                        let authorization = try BrowserAccessAuthorization(directory: directory)
                        if let id { try authorization.revoke(id) } else { try authorization.revokeAll() }
                        return authorization.clients
                    }.value
                    self?.clients = clients
                } catch { self?.error = error.localizedDescription }
            }
        }
    }

    func exportCertificate() {
        guard let certificate else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "zshell-browser-access.pem"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try certificate.write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    private static func sessions() -> [BrowserAccessSession] {
        Array(TerminalManager.automationManagers.flatMap { manager in
            manager.projects.flatMap { project in
                project.sessions.compactMap { session in
                    guard !session.hasExited, session.persistentSessionID != nil,
                          session.remoteConnection == nil, session.remotePasteTarget == nil else { return nil }
                    return BrowserAccessSession(id: session.id,
                        project: String(decoding: project.name.utf8.prefix(128), as: UTF8.self),
                        title: String(decoding: session.title.utf8.prefix(128), as: UTF8.self))
                }
            }
        }.prefix(128))
    }

    private nonisolated static func assets() throws -> [String: (Data, String)] {
        let files = ["index.html": "text/html; charset=utf-8", "browser-access.js": "text/javascript; charset=utf-8",
            "browser-access.css": "text/css; charset=utf-8", "xterm.js": "text/javascript; charset=utf-8",
            "xterm.css": "text/css; charset=utf-8", "addon-fit.js": "text/javascript; charset=utf-8",
            "addon-unicode11.js": "text/javascript; charset=utf-8"]
        var assets: [String: (Data, String)] = [:]
        for (file, type) in files {
            let path = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: path, withExtension: ext, subdirectory: "BrowserAccessWeb")
                    ?? Bundle.main.url(forResource: path, withExtension: ext) else {
                throw BrowserAccessError.message(String(localized: "The browser terminal page is unavailable."))
            }
            assets[file == "index.html" ? "/" : "/" + file] = (try Data(contentsOf: url), type)
        }
        return assets
    }

    private static func translations() -> [String: String] {
        ["title": String(localized: "Browser Access"), "pair": String(localized: "Request Pairing"),
         "name": String(localized: "Client name"), "pairing": String(localized: "Compare this code on the Mac, then approve the client in Settings → Browser Access."),
         "waiting": String(localized: "Waiting for approval…"), "denied": String(localized: "Pairing was denied or expired."),
         "connect": String(localized: "Reconnect"), "disconnect": String(localized: "Disconnect"),
         "forget": String(localized: "Forget This Browser"), "connected": String(localized: "Connected"),
         "disconnected": String(localized: "Disconnected"), "connecting": String(localized: "Connecting…"),
         "session": String(localized: "Terminal session"), "control": String(localized: "Resize terminal to browser"),
         "empty": String(localized: "Open a new terminal pane on this Mac after enabling browser access."),
         "certificate": String(localized: "Export TLS Certificate…"),
         "trust": String(localized: "Before pairing remotely, compare the TLS certificate fingerprint on this Mac and trust that certificate on your client device."),
         "failed": String(localized: "Browser access is unavailable. Check the connection and client authorization."),
         "fingerprint": String(localized: "TLS certificate fingerprint"), "remote": String(localized: "Private network address")]
    }
}
