import Darwin
import Foundation

@main
nonisolated struct SSHConfigHostsTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        var passed = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { print("FAILED: " + message) }
            precondition(condition, message)
            passed += 1
        }
        func write(_ path: String, _ contents: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }
        func source(_ url: URL, limits: SSHConfigHosts.Limits = .init()) -> SSHConfigHosts {
            SSHConfigHosts(configurationURL: url, sshDirectory: ssh, limits: limits)
        }
        func expectLimit(_ url: URL, _ limits: SSHConfigHosts.Limits, _ message: String) throws {
            do {
                _ = try source(url, limits: limits).read()
                preconditionFailure(message)
            } catch SSHConfigHosts.Error.limitExceeded { passed += 1 }
        }

        let lexical = try write(
            "lexical/config",
            #"""
            # Host comment-only
            hOsT = "alpha" beta 'gamma' "two words" *.internal !denied -option user@host bad/host alpha
                HostName should-not-appear.example
                User fixture
            Match host match-only exec "touch never-run"
                HostName ignored.example
            Host a"joined" 'single' "space\"quote" plain#literal delta # trailing
            Host FOO !foo keep !KEEP keep-two !KEEP-TWO
            Host !only-negated? * wildcard? "" --option
            Host 192.0.2.1 _under dash-name
            Host "unclosed quoted
            Host after-error
            """#)
        let lexicalHosts = try source(lexical).read()
        expect(
            lexicalHosts == ["alpha", "beta", "gamma", "ajoined", "single", "delta", "192.0.2.1", "_under", "dash-name", "after-error"],
            "actual Host tokens respect quotes, comments, option safety, negatives and case")
        expect(!lexicalHosts.contains("match-only"), "Match host is not a Host directive")

        let escaped = try write(
            "escapes/config",
            #"""
            Host alpha\ beta later
            Host double\\slash 'back\\slash' single\'quote good
            Host=equals second
            """#)
        expect(
            try source(escaped).read() == ["later", "good", "equals", "second"],
            "OpenSSH escape rules do not split an escaped space into a host")

        let absolute = try write("absolute/shared.conf", "Host absolute\n")
        _ = try write("home/.ssh/relative.conf", "Host relative\nInclude nested/child.conf\n")
        _ = try write("home/.ssh/nested/child.conf", "Host nested\nInclude child.conf\n")
        _ = try write("home/.ssh/child.conf", "Host ssh-root-child\n")
        _ = try write("home/.ssh/parts/20.conf", "Host later-part\n")
        _ = try write("home/.ssh/parts/10.conf", "Host earlier-part\n")
        _ = try write("home/.ssh/parts/.hidden.conf", "Host hidden-part\n")
        _ = try write("home/.ssh/with space.conf", "Host spaced-path\n")
        let includes = try write(
            "override/config",
            """
            Host before
            Include relative.conf \(absolute.path) ~/.ssh/parts/*.conf "with space.conf" missing.conf
            Host after
            """)
        expect(
            try source(includes).read() == [
                "before", "relative", "nested", "ssh-root-child", "absolute", "earlier-part", "later-part", "spaced-path", "after",
            ],
            "relative includes are SSH-rooted, absolute and tilde includes work, glob results follow lexical order")
        let bracket = try write("override/bracket", "Include parts/[12]0.conf\n")
        expect(try source(bracket).read() == ["earlier-part", "later-part"], "Include bracket globs follow OpenSSH file patterns")
        let hidden = try write("override/hidden", "Include parts/.*.conf\n")
        expect(try source(hidden).read() == ["hidden-part"], "dot files require an explicit glob prefix")
        let directoryPattern = try write("override/directory-pattern", "Include p*/1?.conf\n")
        expect(try source(directoryPattern).read() == ["earlier-part"], "wildcards can select intermediate directories")

        let cycle = try write("home/.ssh/cycle-a", "Host cycle-a\nInclude cycle-b\n")
        _ = try write("home/.ssh/cycle-b", "Host cycle-b\nInclude cycle-a cycle-a\n")
        expect(try source(cycle).read() == ["cycle-a", "cycle-b"], "cycles and repeated includes are read once")
        let symlink = ssh.appendingPathComponent("cycle-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: cycle)
        let duplicate = try write("override/duplicate", "Include cycle-a cycle-link cycle-b\nHost CYCLE-A unique\n")
        expect(
            try source(duplicate).read() == ["cycle-a", "cycle-b", "unique"],
            "symlinks and case-insensitive aliases deduplicate by source identity")
        let hardlink = ssh.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: cycle, to: hardlink)
        let hardlinks = try write("override/hardlinks", "Include cycle-a hard-link\n")
        expect(try source(hardlinks).read() == ["cycle-a", "cycle-b"], "hard links deduplicate by inode")
        let loop = ssh.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        let pipe = ssh.appendingPathComponent("pipe")
        expect(mkfifo(pipe.path, 0o600) == 0, "fixture FIFO can be created")
        try FileManager.default.createSymbolicLink(atPath: ssh.appendingPathComponent("pipe-link").path, withDestinationPath: "pipe")
        let nonregular = try write("override/nonregular", "Include pipe pipe-link loop nested missing\nHost regular\n")
        let started = ContinuousClock.now
        expect(try source(nonregular).read() == ["regular"], "FIFO, directory, symlink cycle and missing includes do not block discovery")
        expect(started.duration(to: .now) < .seconds(1), "nonregular includes are rejected promptly")

        let marker = root.appendingPathComponent("match-executed")
        let commandMarker = root.appendingPathComponent("shell-executed")
        let notExecuted = try write(
            "override/no-exec",
            """
            Match exec "touch \(marker.path)" host not-a-host
                ProxyCommand touch \(marker.path)
                IdentityFile \(pipe.path)
            Include "$(touch \(commandMarker.path))" `${touch}`
            Host safe
            """)
        expect(try source(notExecuted).read() == ["safe"], "Match exec and Include shell-looking tokens remain data")
        expect(
            !FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: commandMarker.path),
            "discovery never executes Match, ProxyCommand or shell expansions")
        _ = try write("home/.ssh/key-match", "-----BEGIN OPENSSH PRIVATE KEY-----\nHost key-secret\n-----END OPENSSH PRIVATE KEY-----\n")
        _ = try write("home/.ssh/known_hosts", "Host not-a-config\n")
        let keyInclude = try write("override/key-include", "Include key-match known_hosts\nHost ordinary\n")
        expect(try source(keyInclude).read() == ["ordinary"], "private key headers and known-host files do not become aliases")

        let defaultSource = try SSHConfigHosts.configured(environment: [:], homeDirectory: home)
        expect(try defaultSource.read().isEmpty, "a missing default config is an empty result")
        _ = try write("home/.ssh/config", "Host private-home-default\n")
        expect(try defaultSource.read() == ["private-home-default"], "default discovery uses the supplied home")
        let overrideSource = try SSHConfigHosts.configured(environment: ["ZSHELL_SSH_CONFIG_FILE": includes.path], homeDirectory: home)
        expect(
            overrideSource.configurationURL == includes && overrideSource.sshDirectory == ssh,
            "override and Include roots keep separate ownership")
        expect(try overrideSource.read().first == "before", "valid override discovers the private fixture")
        for path in ["", "relative/config", includes.path + "\n", includes.path + ".missing", ssh.path] {
            do {
                _ = try SSHConfigHosts.configured(environment: ["ZSHELL_SSH_CONFIG_FILE": path], homeDirectory: home)
                preconditionFailure("invalid override fell back to the default configuration")
            } catch SSHEndpoint.ValidationError.invalidConfiguration { passed += 1 }
        }
        do {
            _ = try source(pipe).read()
            preconditionFailure("a nonregular root was accepted")
        } catch SSHConfigHosts.Error.unreadableConfiguration { passed += 1 }
        let invalidUTF8 = root.appendingPathComponent("invalid-utf8")
        try Data([0xFF, 0xFE]).write(to: invalidUTF8)
        do {
            _ = try source(invalidUTF8).read()
            preconditionFailure("invalid UTF8 was accepted")
        } catch SSHConfigHosts.Error.unreadableConfiguration { passed += 1 }

        var limits = SSHConfigHosts.Limits()
        limits.fileBytes = 8
        try expectLimit(lexical, limits, "file-size limit must reject a large configuration")
        limits = .init()
        limits.totalBytes = 30
        try expectLimit(cycle, limits, "total-size limit must count included files")
        limits = .init()
        limits.files = 1
        try expectLimit(cycle, limits, "file-count limit must reject a second unique file")
        let manyMissing = try write("override/many-missing", "Include absent-one absent-two absent-three\n")
        limits = .init()
        limits.files = 2
        try expectLimit(manyMissing, limits, "missing Include paths still count toward the file-attempt limit")
        let manyRepeated = try write("override/repeated", String(repeating: "Include cycle-a\n", count: 100))
        limits = .init()
        limits.files = 3
        expect(
            try source(manyRepeated, limits: limits).read() == ["cycle-a", "cycle-b"],
            "duplicate paths do not reopen or exhaust the file limit")
        limits = .init()
        limits.depth = 0
        try expectLimit(cycle, limits, "include-depth limit must reject recursion")
        limits = .init()
        limits.hosts = 1
        try expectLimit(lexical, limits, "host-count limit must reject extra aliases")
        limits = .init()
        limits.directoryEntries = 1
        try expectLimit(bracket, limits, "directory scan limit must bound a wide glob")

        let cancellationSource = source(lexical)
        let cancelled = Task.detached { () throws -> [String] in
            while !Task.isCancelled { usleep(1_000) }
            return try cancellationSource.read()
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("cancelled discovery returned candidates")
        } catch is CancellationError { passed += 1 }

        let validOpenSSH = try write(
            "openssh/config",
            #"""
            hOsT = "native-one" 'native-two' native-three native-one !excluded
                HostName 127.0.0.1
                User fixture
                Port 2222
                IdentityFile none
                UserKnownHostsFile none
            Host *
                BatchMode yes
            """#)
        let nativeHosts = try source(validOpenSSH).read()
        expect(nativeHosts == ["native-one", "native-two", "native-three"], "a valid OpenSSH fixture yields literal aliases")
        for host in nativeHosts {
            let result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["-G", "-F", validOpenSSH.path, host], timeout: 5, outputLimit: 32_768,
                environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            )
            expect(
                result.terminationStatus == 0 && result.output.stdout.contains("hostname 127.0.0.1\n")
                    && result.output.stdout.contains("user fixture\n") && result.output.stdout.contains("port 2222\n"),
                "OpenSSH recognizes the discovered alias without making a connection")
        }
        print("SSH config discovery: \(passed) passed, 0 failed")
    }
}
