import Foundation

@main
struct RemoteSSHTests {
    static func main() throws {
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            passed += 1
        }

        let endpoint = try SSHEndpoint(
            host: "example.com",
            user: "dev",
            port: 2222
        )
        expect(endpoint.destination == "dev@example.com", "destination")
        expect(
            endpoint.terminalArguments(remoteDirectory: "/srv/a'b").suffix(3)
                == ["-t", "dev@example.com", "cd -- '/srv/a'\\''b' && exec \"${SHELL:-/bin/sh}\" -l"],
            "terminal argv quotes the remote directory"
        )
        // A leading tilde must stay unquoted so the remote shell expands it.
        expect(
            endpoint.terminalArguments(remoteDirectory: "~/my repo").suffix(3)
                == ["-t", "dev@example.com", "cd -- ~/'my repo' && exec \"${SHELL:-/bin/sh}\" -l"],
            "terminal argv expands a tilde remote directory"
        )
        let transport = endpoint.transportArguments(
            connectTimeout: 2.1,
            command: ["printf", "%s", "a'b"]
        )
        expect(transport.contains("BatchMode=yes"), "batch mode")
        expect(transport.contains("NumberOfPasswordPrompts=0"), "password prompts disabled")
        expect(transport.contains("StrictHostKeyChecking=yes"), "unknown hosts rejected")
        expect(transport.contains("ConnectTimeout=3"), "connect timeout rounded up")
        expect(transport.suffix(2) == ["dev@example.com", "'printf' '%s' 'a'\\''b'"], "command quoted")

        let passwordAuthentication = SSHAuthentication.password
        let passwordArguments = endpoint.transportArguments(
            connectTimeout: 2,
            command: [":"],
            authentication: passwordAuthentication
        )
        expect(passwordArguments.contains("BatchMode=no"), "password auth enables askpass")
        expect(
            passwordArguments.contains("PreferredAuthentications=password,keyboard-interactive"),
            "password auth is explicit"
        )
        let privateKeyArguments = endpoint.terminalArguments(
            remoteDirectory: nil,
            authentication: .privateKeyPath("/tmp/id_ed25519"),
            identityFile: "/tmp/id_ed25519"
        )
        expect(privateKeyArguments.contains("IdentityFile=none"), "key auth disables defaults")
        expect(privateKeyArguments.contains("/tmp/id_ed25519"), "key path is passed as argv")

        let authenticationData = try JSONEncoder().encode(SSHAuthentication.privateKeyContent)
        let authenticationJSON = String(decoding: authenticationData, as: UTF8.self)
        expect(!authenticationJSON.contains("PRIVATE KEY"), "authentication JSON excludes key text")

        let legacyLocationData = Data(
            #"{"ssh":{"endpoint":{"host":"example.com","user":"dev","port":2222},"remoteDirectory":"/srv/project"}}"#.utf8
        )
        let legacyLocation = try JSONDecoder().decode(ProjectLocation.self, from: legacyLocationData)
        expect(
            legacyLocation == .ssh(endpoint: endpoint, remoteDirectory: "/srv/project"),
            "legacy SSH location defaults to agent authentication"
        )

        let credentialID = UUID()
        let credentialStore = SSHCredentialStore(
            service: "sh.zshell.remote-ssh-tests.\(UUID().uuidString)"
        )
        defer { credentialStore.remove(credentialID) }
        try credentialStore.save("test-password", for: credentialID)
        let material = try passwordAuthentication.makeMaterial(
            credentialID: credentialID,
            credentialStore: credentialStore
        )
        guard let material else { preconditionFailure("password material missing") }
        let temporaryDirectory = material.temporaryDirectoryURL
        let passwordFile = temporaryDirectory.appendingPathComponent("password")
        let askpassFile = temporaryDirectory.appendingPathComponent("askpass")
        let passwordPermissions = try FileManager.default.attributesOfItem(
            atPath: passwordFile.path
        )[.posixPermissions] as? NSNumber
        let askpassPermissions = try FileManager.default.attributesOfItem(
            atPath: askpassFile.path
        )[.posixPermissions] as? NSNumber
        expect(passwordPermissions?.intValue == 0o600, "password material is private")
        expect(askpassPermissions?.intValue == 0o700, "askpass script is executable and private")
        expect(material.environment["SSH_ASKPASS"] == askpassFile.path, "askpass path is exported")
        material.cleanup()
        expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path), "material is cleaned up")

        expect(SSHEndpoint.shellWord("~") == "~", "bare tilde")
        expect(SSHEndpoint.shellWord("~/my repo") == "~/'my repo'", "tilde home")
        expect(SSHEndpoint.shellWord("~alice/x y") == "~alice/'x y'", "tilde user")
        expect(SSHEndpoint.shellWord("~we ird/x") == "'~we ird/x'", "odd tilde user quoted")
        expect(SSHEndpoint.shellWord("plain path") == "'plain path'", "plain path quoted")

        let gitCommand = endpoint.transportArguments(
            connectTimeout: 5,
            command: ["/usr/bin/git", "-C", "~/repo", "status"]
        )
        expect(
            gitCommand.last?.contains("~/'repo'") == true,
            "git -C keeps tilde expansion"
        )

        let listing = SSHEndpoint.parseDirectoryListing("src/\nREADME.md\n.git/\n\nsub dir/\n")
        expect(
            listing == [
                SSHEndpoint.DirectoryEntry(name: "src", isDirectory: true),
                SSHEndpoint.DirectoryEntry(name: "README.md", isDirectory: false),
                SSHEndpoint.DirectoryEntry(name: "sub dir", isDirectory: true),
            ],
            "listing parse marks directories and hides .git"
        )

        for invalid in ["", "-proxy", "bad host"] {
            do {
                _ = try SSHEndpoint(host: invalid)
                preconditionFailure("invalid host accepted")
            } catch {
                passed += 1
            }
        }
        do {
            _ = try SSHEndpoint(host: "example.com", user: "bad user")
            preconditionFailure("invalid user accepted")
        } catch {
            passed += 1
        }
        do {
            _ = try SSHEndpoint(host: "example.com", port: 65_536)
            preconditionFailure("invalid port accepted")
        } catch {
            passed += 1
        }

        let roundTrip = try JSONDecoder().decode(
            ProjectLocation.self,
            from: JSONEncoder().encode(
                ProjectLocation.ssh(endpoint: endpoint, remoteDirectory: "/srv/project")
            )
        )
        expect(
            roundTrip == .ssh(endpoint: endpoint, remoteDirectory: "/srv/project"),
            "location Codable round trip"
        )

        let bounded = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '123456'; printf 'abcdef' >&2"],
            timeout: 1,
            outputLimit: 7
        )
        expect(!bounded.timedOut, "bounded process completes")
        expect(bounded.output.wasTruncated, "combined output limit reported")
        expect(
            bounded.output.stdout.utf8.count + bounded.output.stderr.utf8.count == 7,
            "combined output is bounded"
        )

        let timedOut = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 5"],
            timeout: 0.05,
            outputLimit: 32
        )
        expect(timedOut.timedOut, "process timeout")

        print("Remote SSH tests: \(passed) passed, 0 failed")
    }
}
