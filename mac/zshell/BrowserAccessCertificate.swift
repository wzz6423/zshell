import CryptoKit
import Foundation
import Network
import Security

nonisolated struct BrowserAccessCertificate: @unchecked Sendable {
    private struct StoredIdentity: Codable {
        let pkcs12: Data
        let password: String
    }
    let identity: SecIdentity
    let certificate: SecCertificate
    let fingerprint: String
    let pem: Data

    static func loadOrCreate(directory: URL, address: String) throws -> Self {
        try BrowserAccessStorage.prepare(directory)
        let url = directory.appendingPathComponent("identity-" + BrowserAccessSecret.digest(address).prefix(16) + ".json")
        if let data = try BrowserAccessStorage.read(url, limit: 96 * 1024),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let saved = try? decode(stored.pkcs12, password: stored.password, address: address) { return saved }
        let temporary = directory.appendingPathComponent("certificate-" + UUID().uuidString, isDirectory: true)
        try BrowserAccessStorage.prepare(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let key = temporary.appendingPathComponent("key.pem")
        let certificate = temporary.appendingPathComponent("certificate.pem")
        let bundle = temporary.appendingPathComponent("identity.p12")
        let executable = URL(fileURLWithPath: "/usr/bin/openssl")
        let create = try BoundedProcessRunner.run(executableURL: executable, arguments: [
            "req", "-new", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "365",
            "-subj", "/CN=Zshell Browser Access", "-addext", "subjectAltName=IP:" + address,
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
            "-addext", "extendedKeyUsage=serverAuth", "-keyout", key.path, "-out", certificate.path,
        ], timeout: 15, outputLimit: 8192)
        guard !create.timedOut, create.terminationStatus == 0 else {
            throw BrowserAccessError.message(String(localized: "Browser access could not create its TLS certificate."))
        }
        let password = try BrowserAccessSecret.random()
        let export = try BoundedProcessRunner.run(executableURL: executable, arguments: [
            "pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out", bundle.path,
            "-passout", "stdin",
        ], timeout: 5, outputLimit: 8192, standardInput: Data((password + "\n").utf8))
        guard !export.timedOut, export.terminationStatus == 0 else {
            throw BrowserAccessError.message(String(localized: "Browser access could not create its TLS certificate."))
        }
        let data = try Data(contentsOf: bundle)
        let result = try decode(data, password: password, address: address)
        try BrowserAccessStorage.write(JSONEncoder().encode(StoredIdentity(pkcs12: data, password: password)), to: url)
        return result
    }

    private static func decode(_ data: Data, password: String, address: String) throws -> Self {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw BrowserAccessError.message(String(localized: "Browser access could not load its TLS identity."))
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw BrowserAccessError.message(String(localized: "Browser access could not load its TLS identity."))
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, address as CFString), &trust) == errSecSuccess,
              let trust, SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            throw BrowserAccessError.message(String(localized: "Browser access TLS certificate is invalid or expired."))
        }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let pem = "-----BEGIN CERTIFICATE-----\n"
            + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END CERTIFICATE-----\n"
        return Self(identity: identity, certificate: certificate, fingerprint: fingerprint, pem: Data(pem.utf8))
    }

    func parameters(interface: BrowserAccessInterface) throws -> NWParameters {
        guard let identity = sec_identity_create(identity), let ipv4 = IPv4Address(interface.address) else {
            throw BrowserAccessError.message(String(localized: "Choose an available private network interface."))
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let network = interface.interface { parameters.requiredInterface = network }
        let scoped = interface.interface.flatMap { IPv4Address(ipv4.rawValue, $0) } ?? ipv4
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(scoped), port: .any)
        parameters.allowLocalEndpointReuse = false
        return parameters
    }
}
