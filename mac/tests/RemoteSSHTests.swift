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
