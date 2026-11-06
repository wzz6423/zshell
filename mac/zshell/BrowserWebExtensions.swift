import AppKit
import Combine
import WebKit

@MainActor
final class BrowserWebExtensionStore: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let version: String
        let resource: String
        let permissions: [String]
        let websites: [String]
        var isEnabled: Bool
    }

    nonisolated enum StoreError: LocalizedError {
        case invalid, tooLarge, unsafeFiles, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "Choose a compatible WebExtension directory or ZIP archive with manifest.json.")
            case .tooLarge: String(localized: "Extension files exceed 64 MiB or 4096 entries.")
            case .unsafeFiles: String(localized: "Extension files must be regular files and directories without symbolic links.")
            case .unavailable: String(localized: "The extension could not be loaded.")
            }
        }
    }

    static let shared = BrowserWebExtensionStore()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var error: String?
    private let directory: URL
    private var runtimes: [String: BrowserWebExtensionRuntime] = [:]
    private var controllerIdentifiers = Set<UUID>()
    private var mutationInProgress = false
    nonisolated private static let maximumBytes = 64 * 1_024 * 1_024
    nonisolated private static let maximumEntries = 4_096
    private static let maximumControllers = 4_096
    private static let localIdentifier = UUID(uuidString: "AC74826B-343D-45F5-AC19-1655669AA643")!

    init(directory: URL? = nil) {
        self.directory = directory ?? AgentUsagePaths.applicationSupportDirectory.appendingPathComponent("browser-extensions", isDirectory: true)
        do {
            let file = self.directory.appendingPathComponent("extensions.json")
            if FileManager.default.fileExists(atPath: file.path) {
                try PersistentCLIConnection.verifyPrivateDirectory(self.directory)
                entries = try JSONDecoder().decode([Entry].self, from: PersistentCLIConnection.readPrivate(file, maximumBytes: 1 << 20))
                guard entries.count <= 32, Set(entries.map(\.id)).count == entries.count,
                      entries.allSatisfy({ ["resources", "resources.zip"].contains($0.resource)
                          && $0.permissions.count <= 128 && $0.websites.count <= 256 }) else { throw StoreError.invalid }
            }
            let controllers = self.directory.appendingPathComponent("controllers.json")
            if FileManager.default.fileExists(atPath: controllers.path) {
                try PersistentCLIConnection.verifyPrivateDirectory(self.directory)
                let saved = try JSONDecoder().decode([UUID].self,
                    from: PersistentCLIConnection.readPrivate(controllers, maximumBytes: 1 << 20))
                guard saved.count <= Self.maximumControllers else { throw StoreError.tooLarge }
                controllerIdentifiers = Set(saved)
            }
        } catch { self.error = error.localizedDescription; entries = [] }
    }

    func runtime(for dataStore: WKWebsiteDataStore, routing: BrowserRemoteRouting?) -> BrowserWebExtensionRuntime {
        let key = dataStore.identifier?.uuidString ?? (dataStore.isPersistent ? "local" : String(describing: ObjectIdentifier(dataStore)))
        if let runtime = runtimes[key] { return runtime }
        let configuration = dataStore.isPersistent
            ? WKWebExtensionController.Configuration(identifier: dataStore.identifier ?? Self.localIdentifier)
            : .nonPersistent()
        configuration.defaultWebsiteDataStore = dataStore
        let runtime = BrowserWebExtensionRuntime(store: self, key: key, configuration: configuration, routing: routing)
        runtimes[key] = runtime
        return runtime
    }

    func release(_ runtime: BrowserWebExtensionRuntime) {
        guard runtime.tabs.isEmpty else { return }
        runtime.stop()
        runtimes[runtime.key] = nil
    }

    func resourceURL(for entry: Entry) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true).appendingPathComponent(entry.resource)
    }

    func prepare(_ source: URL) async throws -> (Entry, WKWebExtension) {
        guard !mutationInProgress, entries.count < 32 else { throw StoreError.unavailable }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try AgentConversationHistoryPaths.prepare(directory)
        let id = UUID()
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try PersistentCLIConnection.preparePrivateDirectory(destination)
        do {
            let archive = try await Task.detached(priority: .userInitiated) { try Self.validate(source) }.value
            let resource = archive ? "resources.zip" : "resources"
            let copied = destination.appendingPathComponent(resource)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: copied)
                _ = try Self.validate(copied)
                try Self.makePrivate(copied)
            }.value
            let webExtension = try await WKWebExtension(resourceBaseURL: copied)
            guard webExtension.errors.isEmpty, let name = webExtension.displayName, !name.isEmpty,
                  webExtension.requestedPermissions.count <= 128, webExtension.allRequestedMatchPatterns.count <= 256 else {
                throw webExtension.errors.first ?? StoreError.invalid
            }
            let entry = Entry(id: id, name: name, version: webExtension.version ?? "", resource: resource,
                permissions: webExtension.requestedPermissions.map(\.rawValue).sorted(),
                websites: webExtension.allRequestedMatchPatterns.map(\.string).sorted(), isEnabled: true)
            return (entry, webExtension)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func install(_ entry: Entry) throws {
        guard !entries.contains(where: { $0.id == entry.id }), entries.count < 32 else { throw StoreError.invalid }
        try persist(entries + [entry])
    }

    func discard(_ entry: Entry) { try? FileManager.default.removeItem(at: resourceURL(for: entry).deletingLastPathComponent()) }

    func report(_ failure: Error) { error = failure.localizedDescription }

    func recordController(_ identifier: UUID?) throws {
        guard let identifier, !controllerIdentifiers.contains(identifier) else { return }
        guard controllerIdentifiers.count < Self.maximumControllers else { throw StoreError.tooLarge }
        let next = controllerIdentifiers.union([identifier])
        try AgentConversationHistoryPaths.prepare(directory)
        try PersistentCLIConnection.writePrivate(try JSONEncoder().encode(next.sorted { $0.uuidString < $1.uuidString }),
            to: directory.appendingPathComponent("controllers.json"), durable: true)
        controllerIdentifiers = next
    }

    func setEnabled(_ enabled: Bool, id: UUID) throws {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw StoreError.unavailable }
        next[index].isEnabled = enabled
        try persist(next)
    }

    func remove(id: UUID) async throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try persist(entries.filter { $0.id != id })
        let controllers = runtimes.values.map(\.controller)
        for controller in controllers { await BrowserWebExtensionRuntime.removeData(for: entry.id, controller: controller) }
        // Closed remote projects still own persistent extension storage.
        let active = Set(controllers.compactMap { $0.configuration.identifier })
        let identifiers = controllerIdentifiers.union(await WKWebsiteDataStore.allDataStoreIdentifiers).union([Self.localIdentifier])
        for identifier in identifiers.subtracting(active) {
            let controller = WKWebExtensionController(configuration: .init(identifier: identifier))
            await BrowserWebExtensionRuntime.removeData(for: entry.id, controller: controller)
        }
        discard(entry)
    }

    private func persist(_ next: [Entry]) throws {
        try AgentConversationHistoryPaths.prepare(directory)
        try PersistentCLIConnection.writePrivate(try JSONEncoder().encode(next), to: directory.appendingPathComponent("extensions.json"), durable: true)
        entries = next
        error = nil
        for runtime in runtimes.values { runtime.refresh() }
    }

    nonisolated static func validate(_ source: URL) throws -> Bool {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard source.isFileURL, values.isSymbolicLink != true else { throw StoreError.unsafeFiles }
        if values.isDirectory == true {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: source,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                errorHandler: { _, error in enumerationError = error; return false }) else { throw StoreError.invalid }
            var bytes = 0, count = 0
            for case let file as URL in enumerator {
                count += 1
                let item = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard item.isSymbolicLink != true, item.isDirectory == true || item.isRegularFile == true else { throw StoreError.unsafeFiles }
                bytes += item.fileSize ?? 0
                guard count <= maximumEntries, bytes <= maximumBytes else { throw StoreError.tooLarge }
            }
            if let enumerationError { throw enumerationError }
            let manifest = source.appendingPathComponent("manifest.json")
            let info = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, (info.fileSize ?? 0) > 0, (info.fileSize ?? 0) <= 1 << 20 else { throw StoreError.invalid }
            return false
        }
        guard values.isRegularFile == true, source.pathExtension.lowercased() == "zip" else { throw StoreError.invalid }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw StoreError.tooLarge }
        // Bound the archive before WebKit expands it, including its declared
        // uncompressed size. ZIP64 and linked resources are not installable.
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        func number(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, offset + size <= data.count else { return nil }
            return (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22, let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first(where: { number($0, 4) == 0x06054b50 && $0 + 22 + (number($0 + 20, 2) ?? -1) == data.count }),
              number(end + 4, 2) == 0, number(end + 6, 2) == 0,
              let count = number(end + 10, 2), count == number(end + 8, 2), count > 0, count <= maximumEntries,
              let start = number(end + 16, 4), let size = number(end + 12, 4), start + size == end else { throw StoreError.invalid }
        var offset = start, total = 0, manifest = false
        var names = Set<String>()
        for _ in 0..<count {
            guard number(offset, 4) == 0x02014b50, let length = number(offset + 28, 2),
                  let extra = number(offset + 30, 2), let comment = number(offset + 32, 2),
                  let bytes = number(offset + 24, 4), let compressed = number(offset + 20, 4),
                  let attributes = number(offset + 38, 4), let local = number(offset + 42, 4),
                  offset + 46 + length + extra + comment <= end,
                  let name = String(data: data[(offset + 46)..<(offset + 46 + length)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(".."), names.insert(name).inserted,
                  [0, 0o040000, 0o100000].contains((attributes >> 16) & 0o170000),
                  number(local, 4) == 0x04034b50, let flags = number(local + 6, 2),
                  flags == number(offset + 8, 2), flags & 1 == 0,
                  number(local + 8, 2) == number(offset + 10, 2),
                  let localLength = number(local + 26, 2), let localExtra = number(local + 28, 2),
                  localLength == length, local + 30 + localLength + localExtra + compressed <= start,
                  data[(local + 30)..<(local + 30 + localLength)] == data[(offset + 46)..<(offset + 46 + length)],
                  flags & 8 != 0 || (number(local + 18, 4) == compressed && number(local + 22, 4) == bytes) else { throw StoreError.unsafeFiles }
            total += bytes
            guard total <= maximumBytes else { throw StoreError.tooLarge }
            manifest = manifest || name == "manifest.json"
            offset += 46 + length + extra + comment
        }
        guard offset == end, manifest else { throw StoreError.invalid }
        return true
    }

    nonisolated private static func makePrivate(_ source: URL) throws {
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: source.path)
        var enumerationError: Error?
        if isDirectory, let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey],
            errorHandler: { _, error in enumerationError = error; return false }) {
            for case let file as URL in enumerator {
                let directory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: file.path)
            }
        }
        if let enumerationError { throw enumerationError }
    }
}

@MainActor
final class BrowserWebExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    let key: String
    private weak var store: BrowserWebExtensionStore?
    private weak var routing: BrowserRemoteRouting?
    private(set) var tabs: [BrowserWebExtensionTab] = []
    private var windows: [ObjectIdentifier?: BrowserWebExtensionWindow] = [:]
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var requestedEntries: [BrowserWebExtensionStore.Entry]?
    private var loading: Task<Void, Never>?
    private var revision: UInt = 0
    private var observation: AnyCancellable?
    private var menuCommands: [BrowserWebExtensionMenuCommand] = []
    private var prompting = false
    private var focusObservers: [NSObjectProtocol] = []
    private var popup: WKWebExtension.Action?
    private let backgroundContent: WKUserContentController

    init(store: BrowserWebExtensionStore, key: String, configuration: WKWebExtensionController.Configuration, routing: BrowserRemoteRouting?) {
        self.store = store
        self.key = key
        self.routing = routing
        // The same rules protect background and popup requests, which do not
        // use BrowserTab's navigation delegate.
        let background = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        background.websiteDataStore = configuration.defaultWebsiteDataStore ?? .default()
        backgroundContent = background.userContentController
        if let routing {
            backgroundContent.addUserScript(WKUserScript(
                source: BrowserRemoteRouting.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            backgroundContent.addScriptMessageHandler(
                routing.loopbackMessageHandler(), contentWorld: .page, name: BrowserRemoteRouting.loopbackMessageName)
        }
        configuration.webViewConfiguration = background
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        observation = BrowserContentBlocker.shared.$ruleLists.sink { [weak self] _ in self?.updateRules() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                assumeMainActor { self?.notifyFocus() }
            })
        }
    }

    deinit { for observer in focusObservers { NotificationCenter.default.removeObserver(observer) } }

    func register(_ browser: BrowserTab) {
        let tab = BrowserWebExtensionTab(browser: browser, runtime: self)
        tabs.append(tab)
        move(browser)
        controller.didOpenTab(tab)
        if loading == nil { refresh() }
    }

    func remove(_ browser: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.browser === browser }) else { return }
        let tab = tabs.remove(at: index)
        controller.didCloseTab(tab)
        removeEmptyWindows()
        store?.release(self)
    }

    func move(_ browser: BrowserTab) {
        guard let tab = tabs.first(where: { $0.browser === browser }) else { return }
        let windowKey = browser.hostManagerID
        if windows[windowKey] == nil {
            let window = BrowserWebExtensionWindow(key: windowKey, runtime: self)
            windows[windowKey] = window
            controller.didOpenWindow(window)
        }
        let previous = tab.hostWindow
        tab.hostWindow = windows[windowKey]
        if let previous, previous !== tab.hostWindow { controller.didMoveTab(tab, from: 0, in: previous) }
        removeEmptyWindows()
        notifyFocus()
    }

    private func removeEmptyWindows() {
        for (key, window) in windows where !tabs.contains(where: { $0.hostWindow === window }) {
            controller.didCloseWindow(window)
            windows[key] = nil
        }
    }

    func changed(_ browser: BrowserTab, properties: WKWebExtension.TabChangedProperties) {
        guard let tab = tabs.first(where: { $0.browser === browser }) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func focused(_ browser: BrowserTab) {
        guard let tab = tabs.first(where: { $0.browser === browser }) else { return }
        controller.didFocusWindow(tab.hostWindow)
        controller.didActivateTab(tab)
    }

    private func notifyFocus() {
        let window = windows.values.first { $0.nativeWindow?.isKeyWindow == true }
        controller.didFocusWindow(window)
        if let tab = window?.active { controller.didActivateTab(tab) }
    }

    func refresh() {
        guard let store else { return }
        let enabled = store.entries.filter(\.isEnabled)
        guard requestedEntries != enabled || loading == nil && enabled.contains(where: { contexts[$0.id] == nil }) else { return }
        requestedEntries = enabled
        revision &+= 1
        loading?.cancel()
        loading = nil
        for (id, context) in contexts where !enabled.contains(where: { $0.id == id }) {
            context.action(for: nil)?.closePopup()
            if popup?.webExtensionContext === context { popup?.closePopup(); popup = nil }
            BrowserWebExtensionManager.shared.closeOptions(for: context)
            try? controller.unload(context)
            contexts[id] = nil
        }
        guard enabled.contains(where: { contexts[$0.id] == nil }) else { return }
        let current = revision
        loading = Task { [weak self] in
            guard let self else { return }
            if let routing = self.routing {
                do { try await routing.ensureLoopbackRules() }
                catch {
                    if self.revision == current { store.report(error); self.loading = nil }
                    return
                }
            }
            guard self.revision == current, !Task.isCancelled else { return }
            self.updateRules()
            do { try store.recordController(self.controller.configuration.identifier) }
            catch { store.report(error); self.loading = nil; return }
            for entry in enabled where self.contexts[entry.id] == nil {
                do {
                    let url = store.resourceURL(for: entry)
                    _ = try await Task.detached(priority: .utility) { try BrowserWebExtensionStore.validate(url) }.value
                    let webExtension = try await WKWebExtension(resourceBaseURL: url)
                    guard self.revision == current, !Task.isCancelled else { return }
                    guard webExtension.errors.isEmpty else { throw webExtension.errors[0] }
                    let context = WKWebExtensionContext(for: webExtension)
                    context.uniqueIdentifier = entry.id.uuidString.lowercased()
                    context.baseURL = URL(string: "webkit-extension://\(entry.id.uuidString.lowercased())/")!
                    context.grantedPermissions = Dictionary(uniqueKeysWithValues: entry.permissions.map { (WKWebExtension.Permission(rawValue: $0), Date.distantFuture) })
                    context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: try entry.websites.map { (try WKWebExtension.MatchPattern(string: $0), Date.distantFuture) })
                    context.unsupportedAPIs = ["browser.runtime.connectNative", "browser.runtime.sendNativeMessage", "browser.windows.create", "browser.windows.remove", "browser.windows.update"]
                    try self.controller.load(context)
                    self.contexts[entry.id] = context
                } catch { if self.revision == current { store.report(error) } }
            }
            if self.revision == current { self.loading = nil }
        }
    }

    private func updateRules() {
        let rules = BrowserContentBlocker.shared.ruleLists + [routing?.loopbackRules].compactMap { $0 }
        backgroundContent.removeAllContentRuleLists()
        for rule in rules { backgroundContent.add(rule) }
    }

    func stop() {
        revision &+= 1
        loading?.cancel()
        loading = nil
        popup?.closePopup()
        popup = nil
        for context in contexts.values {
            BrowserWebExtensionManager.shared.closeOptions(for: context)
            try? controller.unload(context)
        }
        contexts = [:]
        observation = nil
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
    }

    static func removeData(for id: UUID, controller: WKWebExtensionController) async {
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
            .filter { $0.uniqueIdentifier == id.uuidString.lowercased() }
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
    }

    func menu(for browser: BrowserTab, into menu: NSMenu) {
        guard let store, let tab = tabs.first(where: { $0.browser === browser }) else { return }
        menuCommands = []
        let submenu = NSMenu()
        for entry in store.entries where entry.isEnabled {
            guard let context = contexts[entry.id] else { continue }
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            if let action = context.action(for: tab) {
                let command = BrowserWebExtensionMenuCommand { [weak self, weak tab] in
                    guard let self, let tab, tab.browser?.isClosed == false else { return }
                    self.controller.didActivateTab(tab)
                    tab.performAction(context)
                }
                menuCommands.append(command)
                let run = NSMenuItem(title: action.label.isEmpty ? String(localized: "Open") : action.label,
                                     action: #selector(BrowserWebExtensionMenuCommand.invoke), keyEquivalent: "")
                run.target = command
                run.isEnabled = action.isEnabled
                run.image = action.icon(for: NSSize(width: 16, height: 16))
                actions.addItem(run)
            }
            if context.optionsPageURL != nil {
                let command = BrowserWebExtensionMenuCommand { [weak self, weak browser] in
                    guard let self, let browser else { return }
                    BrowserWebExtensionManager.shared.showOptions(context, relativeTo: browser.webView.window, runtime: self)
                }
                menuCommands.append(command)
                let options = NSMenuItem(title: String(localized: "Options"), action: #selector(BrowserWebExtensionMenuCommand.invoke), keyEquivalent: "")
                options.target = command
                actions.addItem(options)
            }
            item.submenu = actions
            submenu.addItem(item)
            for menuItem in context.menuItems(for: tab) { submenu.addItem(menuItem) }
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        let command = BrowserWebExtensionMenuCommand { [weak store, weak browser] in
            guard let store else { return }
            BrowserWebExtensionManager.shared.show(store: store, relativeTo: browser?.webView.window)
        }
        menuCommands.append(command)
        let manage = NSMenuItem(title: String(localized: "Manage Extensions…"), action: #selector(BrowserWebExtensionMenuCommand.invoke), keyEquivalent: "")
        manage.target = command
        submenu.addItem(manage)
        let item = NSMenuItem(title: String(localized: "Extensions"), action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("zshell.browser.extensions")
        menu.items.filter { $0.identifier == item.identifier }.forEach { menu.removeItem($0) }
        item.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(item)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows.values.sorted { ($0.nativeWindow?.isKeyWindow == true ? 0 : 1) < ($1.nativeWindow?.isKeyWindow == true ? 0 : 1) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windows.values.first { $0.nativeWindow?.isKeyWindow == true }
    }

    private func prompt(_ context: WKWebExtensionContext, details: [String], in tab: (any WKWebExtensionTab)?, completion: @escaping (Bool) -> Void) {
        let popupHost = popup?.webExtensionContext === context
            ? (popup?.associatedTab as? BrowserWebExtensionTab)?.browser?.webView.window : nil
        guard !prompting, let host = (tab as? BrowserWebExtensionTab)?.browser?.webView.window
            ?? popupHost
            ?? windows.values.compactMap(\.nativeWindow).first(where: \.isKeyWindow),
              host.isVisible, host.attachedSheet == nil, details.count <= 256,
              details.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else { completion(false); return }
        prompting = true
        let alert = BrowserWebExtensionManager.permissionAlert(name: context.webExtension.displayName ?? "", details: details, installing: false)
        alert.beginSheetModal(for: host) { [weak self] response in
            guard let self else { completion(false); return }
            self.prompting = false
            completion(response == .alertFirstButtonReturn && context.isLoaded)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        prompt(context, details: permissions.map(\.rawValue).sorted(), in: tab) { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        prompt(context, details: patterns.map(\.string).sorted(), in: tab) { completionHandler($0 ? patterns : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        prompt(context, details: urls.map(\.absoluteString).sorted(), in: tab) { completionHandler($0 ? urls : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let browser = (action.associatedTab as? BrowserWebExtensionTab)?.browser,
              !browser.isClosed, browser.webView.window?.isVisible == true, let popover = action.popupPopover else {
            completionHandler(BrowserWebExtensionStore.StoreError.unavailable)
            return
        }
        if popup !== action { popup?.closePopup() }
        popup = action
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: browser.webView.bounds.midX, y: browser.webView.bounds.maxY - 12, width: 1, height: 1),
                     of: browser.webView, preferredEdge: .minY)
        completionHandler(nil)
    }
}

@MainActor
final class BrowserWebExtensionWindow: NSObject, WKWebExtensionWindow {
    private weak var runtime: BrowserWebExtensionRuntime?
    init(key: ObjectIdentifier?, runtime: BrowserWebExtensionRuntime) { self.runtime = runtime }
    var nativeWindow: NSWindow? { ownedTabs.compactMap { $0.browser?.webView.window }.first }
    private var ownedTabs: [BrowserWebExtensionTab] { runtime?.tabs.filter { $0.hostWindow === self } ?? [] }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { ownedTabs }
    var active: (any WKWebExtensionTab)? { ownedTabs.first(where: \.isActive) ?? ownedTabs.first }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { active }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { nativeWindow?.isMiniaturized == true ? .minimized : .normal }
}

@MainActor
final class BrowserWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var browser: BrowserTab?
    weak var hostWindow: BrowserWebExtensionWindow?
    private weak var runtime: BrowserWebExtensionRuntime?
    private weak var gestureContext: WKWebExtensionContext?
    init(browser: BrowserTab, runtime: BrowserWebExtensionRuntime) { self.browser = browser; self.runtime = runtime }
    var isActive: Bool {
        guard let browser else { return false }
        return TerminalManager.automationManagers.contains { manager in
            ObjectIdentifier(manager) == browser.hostManagerID && manager.selectedProject?.focusedContent?.id == browser.id
        }
    }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { hostWindow }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { browser?.webView }
    func title(for context: WKWebExtensionContext) -> String? { browser?.title }
    func url(for context: WKWebExtensionContext) -> URL? { browser?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { browser?.navigationIsLoading == false }
    func size(for context: WKWebExtensionContext) -> CGSize { browser?.webView.bounds.size ?? .zero }
    func isSelected(for context: WKWebExtensionContext) -> Bool { isActive }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { gestureContext === context }
    func performAction(_ context: WKWebExtensionContext) {
        // Ordinary page clicks must not grant activeTab access to an extension.
        gestureContext = context
        defer { gestureContext = nil }
        context.performAction(for: self)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let browser, !browser.isClosed, BrowserAutomation.isAllowedURL(url, isMainFrame: true) else {
            completionHandler(BrowserWebExtensionStore.StoreError.unavailable); return
        }
        browser.navigateFromExtension(url)
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let browser, !browser.isClosed else { completionHandler(BrowserWebExtensionStore.StoreError.unavailable); return }
        browser.reload()
        completionHandler(nil)
    }
}

@MainActor
private final class BrowserWebExtensionMenuCommand: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
