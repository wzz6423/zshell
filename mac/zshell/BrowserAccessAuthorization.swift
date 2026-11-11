import Darwin
import Foundation

nonisolated enum BrowserAccessStorage {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw BrowserAccessError.message(String(localized: "Browser access requires a private state directory."))
        }
    }

    static func read(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("open browser access state") }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= limit else {
            throw BrowserAccessError.message(String(localized: "Browser access state must be a private regular file."))
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw PTYMuxWire.errnoError("read browser access state") }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try prepare(directory)
        _ = try read(url, limit: 2 * 1024 * 1024)
        let temporary = directory.appendingPathComponent(".browser-access-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PTYMuxWire.errnoError("create browser access state") }
        defer { Darwin.close(descriptor); unlink(temporary.path) }
        try PTYMuxWire.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw PTYMuxWire.errnoError("save browser access state")
        }
    }
}

nonisolated struct BrowserAccessClient: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let address: String
    let origin: String
    let approvedAt: Date
    let expiresAt: Date
    let tokenDigest: String
}

nonisolated struct BrowserAccessPairing: Equatable, Identifiable, Sendable {
    enum State: Equatable { case pending, approved, denied }
    let id: UUID
    let name: String
    let address: String
    let origin: String
    let code: String
    let expiresAt: Date
    let ticketDigest: String
    var state = State.pending
    var clientID: UUID?
    var token: String?
}

/// Called on the service queue, including revocations, before any terminal
/// input. Only credential hashes survive an app restart.
nonisolated final class BrowserAccessAuthorization {
    private let stateURL: URL
    private let now: () -> Date
    private(set) var clients: [BrowserAccessClient] = []
    private(set) var pairings: [BrowserAccessPairing] = []
    private var attempts: [String: [Date]] = [:]

    init(directory: URL, now: @escaping () -> Date = Date.init) throws {
        try BrowserAccessStorage.prepare(directory)
        stateURL = directory.appendingPathComponent("clients.json")
        self.now = now
        if let data = try BrowserAccessStorage.read(stateURL, limit: 64 * 1024) {
            let stored = try JSONDecoder().decode([BrowserAccessClient].self, from: data)
            guard stored.count <= BrowserAccessLimits.clients, Set(stored.map(\.id)).count == stored.count,
                  stored.allSatisfy({ BrowserAccessSecret.isValid($0.tokenDigest) && $0.name.utf8.count <= 128
                      && $0.origin.utf8.count <= 128 && $0.address.utf8.count <= 64 }) else {
                throw BrowserAccessError.message(String(localized: "Browser access authorization state is invalid."))
            }
            clients = stored.filter { $0.expiresAt > now() }
        }
    }

    func expire() {
        clients.removeAll { $0.expiresAt <= now() }
        pairings.removeAll { $0.expiresAt <= now() }
        attempts = attempts.mapValues { $0.filter { $0 > now().addingTimeInterval(-60) } }
            .filter { !$0.value.isEmpty }
    }

    func begin(name: String, address: String, origin: String) throws -> (ticket: String, code: String) {
        expire()
        guard pairings.count < BrowserAccessLimits.pendingPairings,
              clients.count < BrowserAccessLimits.clients, allowAttempt(address),
              !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BrowserAccessError.message(String(localized: "Pairing is unavailable. Try again later."))
        }
        let ticket = try BrowserAccessSecret.random()
        let digits = try BrowserAccessSecret.random().prefix(8).uppercased()
        let code = String(digits.prefix(4)) + "-" + String(digits.suffix(4))
        pairings.append(BrowserAccessPairing(id: UUID(), name: name, address: address, origin: origin,
            code: code, expiresAt: now().addingTimeInterval(BrowserAccessLimits.pairingSeconds),
            ticketDigest: BrowserAccessSecret.digest(ticket)))
        return (ticket, code)
    }

    func approve(_ id: UUID) throws {
        expire()
        guard let index = pairings.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return }
        guard clients.count < BrowserAccessLimits.clients else {
            throw BrowserAccessError.message(String(localized:
                "The authorized client limit has been reached. Revoke a client before approving another."))
        }
        let token = try BrowserAccessSecret.random()
        let pairing = pairings[index]
        let client = BrowserAccessClient(id: UUID(), name: pairing.name, address: pairing.address,
            origin: pairing.origin, approvedAt: now(), expiresAt: now().addingTimeInterval(90 * 24 * 3600),
            tokenDigest: BrowserAccessSecret.digest(token))
        try persist(clients + [client])
        clients.append(client)
        pairings[index].state = .approved
        pairings[index].clientID = client.id
        pairings[index].token = token
    }

    func deny(_ id: UUID) {
        if let index = pairings.firstIndex(where: { $0.id == id }) {
            pairings[index].state = .denied
            pairings[index].token = nil
        }
    }

    func status(ticket: String, address: String, origin: String) -> (state: String, token: String?) {
        expire()
        guard BrowserAccessSecret.isValid(ticket),
              let index = pairings.firstIndex(where: {
                  $0.ticketDigest == BrowserAccessSecret.digest(ticket) && $0.address == address && $0.origin == origin
              }) else { return ("expired", nil) }
        switch pairings[index].state {
        case .pending: return ("pending", nil)
        case .denied: pairings.remove(at: index); return ("denied", nil)
        case .approved:
            let token = pairings[index].token
            pairings.remove(at: index)
            return ("approved", token)
        }
    }

    func authenticate(token: String, origin: String) -> BrowserAccessClient? {
        guard BrowserAccessSecret.isValid(token) else { return nil }
        let digest = BrowserAccessSecret.digest(token)
        return clients.first { $0.tokenDigest == digest && $0.origin == origin && $0.expiresAt > now() }
    }

    func isAuthorized(_ id: UUID, origin: String) -> Bool {
        clients.contains { $0.id == id && $0.origin == origin && $0.expiresAt > now() }
    }

    func revoke(_ id: UUID) throws {
        clients.removeAll { $0.id == id }
        pairings.removeAll { $0.clientID == id }
        try persist(clients)
    }

    func revokeAll() throws {
        clients.removeAll()
        clearPending()
        try persist(clients)
    }

    func clearPending() { pairings.removeAll(); attempts.removeAll() }

    func allowAttempt(_ address: String) -> Bool {
        expire()
        // The map shares the service's connection bound, so spoofed addresses
        // cannot turn authentication rate limiting into an unbounded cache.
        guard attempts[address] != nil || attempts.count < 64 else { return false }
        var history = attempts[address] ?? []
        guard history.count < 12 else { return false }
        history.append(now())
        attempts[address] = history
        return true
    }

    private func persist(_ clients: [BrowserAccessClient]) throws {
        try BrowserAccessStorage.write(JSONEncoder().encode(clients), to: stateURL)
    }
}
