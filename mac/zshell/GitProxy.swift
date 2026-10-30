//
//  GitProxy.swift
//  zshell
//

import Foundation

/// The proxy configured in Settings for Git and GitHub CLI traffic. Git
/// processes are launched from background queues, so AppSettings publishes a
/// lock-protected snapshot here instead of being read off the main actor.
nonisolated enum GitProxy {
    /// Off by default: a loopback proxy that is not running would break every
    /// fetch, push, and PR lookup for anyone who does not use one.
    static let defaultEnabled = false
    static let defaultAddress = "http://127.0.0.1:7897"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeAddress: String?

    /// The proxy in effect, or `nil` when disabled or invalid.
    static var address: String? { lock.withLock { activeAddress } }

    static func update(enabled: Bool, address: String) {
        let value = enabled ? normalized(address) : nil
        lock.withLock { activeAddress = value }
    }

    /// Returns the trimmed address when Git and `gh` can both use it, or `nil`.
    /// SOCKS4 is left out: Git accepts it, but `gh`'s Go transport does not, so
    /// Git would work while every pull request lookup failed.
    static func normalized(_ address: String) -> String? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.query == nil, components.fragment == nil,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    /// For processes Zshell runs itself. The proxy variables cover `gh`; the
    /// Git setting takes precedence over any `http.proxy` in the user's config.
    static func processEnvironment(inheriting environment: [String: String]) -> [String: String] {
        guard let address else { return environment }
        var result = environment
        for key in ["https_proxy", "http_proxy", "all_proxy", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
            result[key] = address
        }
        result.merge(gitConfiguration(address, inheriting: environment), uniquingKeysWith: { _, proxy in proxy })
        return result
    }

    /// For new local terminals. Only Git sees the proxy, so other programs the
    /// user starts in the shell keep their own network settings.
    static func terminalEnvironment(inheriting environment: [String: String]) -> [String: String] {
        address.map { gitConfiguration($0, inheriting: environment) } ?? [:]
    }

    /// `GIT_CONFIG_COUNT` entries are numbered, so append after any the
    /// environment already defines. The earlier entries are repeated because a
    /// reused PTY daemon merges these overrides into its own older environment,
    /// where a raised count without them would make every Git command fail.
    private static func gitConfiguration(_ address: String, inheriting environment: [String: String]) -> [String: String] {
        let index = environment["GIT_CONFIG_COUNT"].flatMap(Int.init).map { max(0, $0) } ?? 0
        var result = [
            "GIT_CONFIG_COUNT": String(index + 1),
            "GIT_CONFIG_KEY_\(index)": "http.proxy",
            "GIT_CONFIG_VALUE_\(index)": address,
        ]
        for inherited in 0..<index {
            for key in ["GIT_CONFIG_KEY_\(inherited)", "GIT_CONFIG_VALUE_\(inherited)"] {
                result[key] = environment[key]
            }
        }
        return result
    }
}
