import Foundation

/// A file's host and authentication stay attached to it after project selection changes.
nonisolated struct RemoteFileSource: Equatable, Sendable {
    let endpoint: SSHEndpoint
    let root: String
    var authentication: SSHAuthentication = .agent
    var credentialID: UUID?

    func displayPath(_ path: String) -> String { endpoint.destination + ":" + path }
}

nonisolated enum FileSource: Equatable, Sendable {
    case local
    case remote(RemoteFileSource)
    case unavailableRemote

    var isRemote: Bool { self != .local }

    func sharesFilesystem(with other: Self) -> Bool {
        switch (self, other) {
        case (.local, .local): true
        case (.remote(let first), .remote(let second)):
            first.endpoint == second.endpoint && first.authentication == second.authentication && first.credentialID == second.credentialID
        default: false
        }
    }
}

nonisolated struct RemoteFileSnapshot: Codable, Equatable, Sendable {
    let path: String
    let root: String
    let rootIdentity: String
    let identity: String?
    let kind: String
    let size: Int64
    let modified: String
    let data: Data?

    var isMissing: Bool { kind == "missing" }
    var isRegular: Bool { kind == "file" }
    var canWrite: Bool { isMissing || isRegular }
    var text: String? {
        guard let data, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The existing comparison dialog only uses file type and bytes, never local I/O.
    var comparison: FileSaveSnapshot {
        FileSaveSnapshot(destinationPath: path,
            identity: identity.map { _ in .init(device: 0, inode: 0, type: isRegular ? 0o100000 : 0) },
            data: data, size: size, modificationSeconds: 0, modificationNanoseconds: 0)
    }
}

nonisolated struct RemoteFileCapabilities: Codable, Equatable, Sendable {
    let create: Bool
    let rename: Bool
    let trash: Bool
    let save: Bool

    static let unavailable = Self(create: false, rename: false, trash: false, save: false)
}

nonisolated struct RemoteTrashEntry: Codable, Equatable, Sendable {
    let original: String
    let path: String
    let root: String
    let identity: String
}

nonisolated struct RemoteFileService: Sendable {
    var transport = OpenSSHTransport(timeout: 30, outputLimit: 8 << 20)

    enum SaveResult: Sendable {
        case saved(RemoteFileSnapshot)
        case conflict(RemoteFileSnapshot)
    }

    enum Failure: LocalizedError, Equatable {
        case unsupported
        case invalidResponse
        case unsafePath
        case busy
        case collision
        case changed
        case tooLarge
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "The remote system tools do not support this safe file operation.")
            case .invalidResponse: String(localized: "The remote host returned an invalid file response.")
            case .unsafePath: String(localized: "Choose a regular file or folder inside the remote project. Symbolic links and special files are not supported.")
            case .busy: String(localized: "Another remote file change is in progress. Try again after it finishes.")
            case .collision: String(localized: "An item already exists at the remote destination. Nothing was replaced.")
            case .changed: String(localized: "The remote file changed during the operation. Your draft was kept.")
            case .tooLarge: String(localized: "Remote text files must be no larger than 5 MiB.")
            case .unavailable: String(localized: "The remote file could not be read.")
            }
        }
    }

    static let maximumBytes = 5 << 20

    func capabilities(source: RemoteFileSource) throws -> RemoteFileCapabilities {
        do { return try request(source: source, operation: "capabilities", path: source.root).capabilities ?? .unavailable }
        catch Failure.unsupported { return .unavailable }
    }

    func read(source: RemoteFileSource, path: String) throws -> RemoteFileSnapshot {
        guard let snapshot = try request(source: source, operation: "read", path: path).snapshot else { throw Failure.invalidResponse }
        return snapshot
    }

    func save(source: RemoteFileSource, path: String, text: String,
              baseline: RemoteFileSnapshot?, overwrite: RemoteFileSnapshot? = nil) throws -> SaveResult {
        guard text.utf8.count <= Self.maximumBytes else { throw Failure.tooLarge }
        var data = Data(text.utf8)
        let bom = Data([0xEF, 0xBB, 0xBF])
        if baseline?.data?.starts(with: bom) == true, !data.starts(with: bom) { data.insert(contentsOf: bom, at: 0) }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        let response = try request(source: source, operation: "save", path: path, data: data, expected: overwrite ?? baseline)
        guard let snapshot = response.snapshot else { throw Failure.invalidResponse }
        return response.conflict == true ? .conflict(snapshot) : .saved(snapshot)
    }

    func create(source: RemoteFileSource, directory: String, name: String, isDirectory: Bool) throws -> String {
        try validateName(name)
        let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
        _ = try request(source: source, operation: isDirectory ? "mkdir" : "create", path: path)
        return path
    }

    func rename(source: RemoteFileSource, path: String, name: String) throws -> String {
        try validateName(name)
        _ = try request(source: source, operation: "rename", path: path, name: name)
        return (path as NSString).deletingLastPathComponent + "/" + name
    }

    func trash(source: RemoteFileSource, path: String) throws -> RemoteTrashEntry {
        guard let entry = try request(source: source, operation: "trash", path: path).trash else { throw Failure.invalidResponse }
        return entry
    }

    func restore(source: RemoteFileSource, entry: RemoteTrashEntry) throws -> String {
        _ = try request(source: source, operation: "restore", path: entry.original, trash: entry)
        return entry.original
    }

    private struct Request: Encodable {
        let operation: String
        let relative: String
        let path: String
        let name: String?
        let data: Data?
        let expected: RemoteFileSnapshot?
        let trash: RemoteTrashEntry?
    }

    private struct Response: Decodable {
        let error: String?
        let snapshot: RemoteFileSnapshot?
        let capabilities: RemoteFileCapabilities?
        let conflict: Bool?
        let trash: RemoteTrashEntry?
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              name != ".zshell-trash", !name.hasPrefix(".zshell-file-") else { throw Failure.unsafePath }
    }

    private func request(source: RemoteFileSource, operation: String, path: String, name: String? = nil,
                         data: Data? = nil, expected: RemoteFileSnapshot? = nil, trash: RemoteTrashEntry? = nil) throws -> Response {
        try Task.checkCancellation()
        let root = source.root == "/" ? "/" : source.root.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        guard !root.isEmpty, (root.hasPrefix("/") || root == "~" || root.hasPrefix("~/") || root.hasPrefix("~")),
              path.utf8.count <= 16_384,
              !root.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.unsafePath }
        let relative: String
        if path == root { relative = "" }
        else {
            let prefix = root == "/" ? "/" : root + "/"
            guard path.hasPrefix(prefix) else { throw Failure.unsafePath }
            relative = String(path.dropFirst(prefix.count))
        }
        guard relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            relative.isEmpty || (!$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".zshell-trash" && !$0.hasPrefix(".zshell-file-"))
        }) else { throw Failure.unsafePath }
        let payload = try JSONEncoder().encode(Request(operation: operation, relative: relative, path: path,
                                                     name: name, data: data, expected: expected, trash: trash))
        let output: BoundedProcessOutput
        do {
            output = try transport.run(endpoint: source.endpoint,
                command: ["/bin/sh", "-c", #"command -v perl >/dev/null 2>&1 || exit 69; exec perl -e "$1" -- "$2""#, "zshell-files", Self.script, root],
                authentication: source.authentication, credentialID: source.credentialID, standardInput: payload)
        } catch OpenSSHTransport.TransportError.failed(let status, _) where status == 69 { throw Failure.unsupported }
        guard !output.wasTruncated, output.stdoutIsValidUTF8, let bytes = output.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: bytes) else { throw Failure.invalidResponse }
        switch response.error {
        case nil: return response
        case "unsupported": throw Failure.unsupported
        case "unsafe": throw Failure.unsafePath
        case "busy": throw Failure.busy
        case "collision": throw Failure.collision
        case "changed": throw Failure.changed
        case "large": throw Failure.tooLarge
        default: throw Failure.unavailable
        }
    }

    /// No remote installation: missing core modules or atomic syscalls disable the affected operation.
    static let script = #"""
    use strict;
    use warnings;
    my $loaded = eval {
      require Fcntl; Fcntl->import(qw(:DEFAULT :flock :mode));
      require JSON::PP; require MIME::Base64; require Digest::SHA;
      require Encode; require File::Temp; require Time::HiRes;
      1;
    };
    if (!$loaded) { print '{"error":"unsupported"}'; exit 0; }
    my $json = JSON::PP->new->utf8;
    sub reply { print $json->encode($_[0]); exit 0; }
    sub fail { reply({error => $_[0]}); }
    my $nofollow = eval { Fcntl::O_NOFOLLOW() };
    my $directory = eval { Fcntl::O_DIRECTORY() };
    fail('unsupported') unless $nofollow && $directory;
    my $request;
    {
      my $input = '';
      while (length($input) <= 15 * 1024 * 1024) {
        my $count = sysread(STDIN, my $chunk, 65536);
        fail('unavailable') unless defined($count);
        last unless $count;
        $input .= $chunk;
      }
      fail('large') if length($input) > 15 * 1024 * 1024;
      $request = eval { $json->decode($input) };
    }
    fail('unsafe') unless ref($request) eq 'HASH';
    sub bytes { return Encode::encode('UTF-8', $_[0], Encode::FB_CROAK() | Encode::LEAVE_SRC()); }
    sub text { return Encode::decode('UTF-8', $_[0], Encode::FB_CROAK() | Encode::LEAVE_SRC()); }
    sub ident { return join(':', @{$_[0]}[0, 1, 2]); }
    sub stamp { return join(':', @{$_[0]}[0, 1, 2, 3, 4, 5, 7, 9, 10]); }
    sub name_ok {
      my ($name) = @_;
      return length($name) && length($name) <= 255 && $name ne '.' && $name ne '..'
        && $name ne '.zshell-trash' && $name !~ /^\.zshell-file-/ && $name !~ m{[/\x00-\x1f\x7f]};
    }
    sub open_directory {
      my ($path) = @_;
      sysopen(my $handle, $path, Fcntl::O_RDONLY() | $nofollow | $directory) or fail('unsafe');
      return $handle;
    }
    my $root_path = shift @ARGV;
    fail('unsafe') unless defined($root_path) && $root_path =~ m{^/};
    chdir('/') or fail('unsafe');
    my $root = open_directory('.');
    for my $component (split m{/}, $root_path) {
      next if $component eq '';
      fail('unsafe') if $component eq '.' || $component eq '..';
      $root = open_directory($component);
      chdir($root) or fail('unsafe');
    }
    my @root_stat = Time::HiRes::stat($root);
    my $root_identity = ident(\@root_stat);
    my $relative = bytes($request->{relative} // '');
    my @components = length($relative) ? split(m{/}, $relative, -1) : ();
    fail('unsafe') if grep { !name_ok($_) } @components;
    my $leaf = pop @components;
    my $parent = $root;
    for my $component (@components) { $parent = open_directory($component); chdir($parent) or fail('unsafe'); }
    my $operation = $request->{operation} // '';
    my @cleanup;
    my $cleanup_directory = $parent;
    END { if ($cleanup_directory) { chdir($cleanup_directory); for my $path (@cleanup) { unlink($path); rmdir($path); } } }
    $SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub { exit 1; };
    sub snapshot {
      my ($name) = @_;
      my @entry = Time::HiRes::lstat($name);
      if (!@entry) {
        fail('unavailable') unless $!{ENOENT};
        return {path => $request->{path}, root => text($root_path), rootIdentity => $root_identity,
          kind => 'missing', size => 0, modified => ''};
      }
      my $kind = Fcntl::S_ISREG($entry[2]) ? 'file' : Fcntl::S_ISDIR($entry[2]) ? 'directory' : 'other';
      my $result = {path => $request->{path}, root => text($root_path), rootIdentity => $root_identity,
        identity => ident(\@entry), kind => $kind, size => 0 + $entry[7], modified => stamp(\@entry)};
      return $result unless $kind eq 'file' && $entry[7] <= 5 * 1024 * 1024;
      sysopen(my $file, $name, Fcntl::O_RDONLY() | Fcntl::O_NONBLOCK() | $nofollow) or fail('unsafe');
      my @before = Time::HiRes::stat($file);
      fail('changed') unless ident(\@before) eq ident(\@entry) && Fcntl::S_ISREG($before[2]);
      my $data = '';
      while (length($data) <= 5 * 1024 * 1024) {
        my $count = sysread($file, my $chunk, 65536);
        fail('unavailable') unless defined($count);
        last unless $count;
        $data .= $chunk;
      }
      my @after = Time::HiRes::stat($file);
      my @latest = Time::HiRes::lstat($name);
      fail('changed') unless @latest && stamp(\@before) eq stamp(\@after) && stamp(\@after) eq stamp(\@latest);
      $result->{data} = MIME::Base64::encode_base64($data, '') if length($data) <= 5 * 1024 * 1024;
      return $result;
    }
    sub matches {
      my ($current, $expected) = @_;
      return 0 unless ref($expected) eq 'HASH';
      for my $key (qw(path root rootIdentity identity kind size modified data)) {
        return 0 if ($current->{$key} // '') ne ($expected->{$key} // '');
      }
      return 1;
    }
    if ($operation eq 'read') { fail('unsafe') unless defined($leaf); reply({snapshot => snapshot($leaf)}); }
    my $locked = flock($root, Fcntl::LOCK_EX() | Fcntl::LOCK_NB());
    if (!$locked && $operation eq 'capabilities') {
      for (1..40) { Time::HiRes::sleep(0.05); $locked = flock($root, Fcntl::LOCK_EX() | Fcntl::LOCK_NB()); last if $locked; }
    }
    fail('busy') unless $locked;
    my $rename_number;
    my $exclusive_flag;
    if ($^O eq 'darwin') { $rename_number = 488; $exclusive_flag = 4; }
    elsif ($^O eq 'linux') {
      eval { require 'syscall.ph'; $rename_number = &SYS_renameat2; $exclusive_flag = 1; };
    }
    sub exclusive_rename {
      my ($from_fd, $from, $to_fd, $to) = @_;
      return 0 unless defined($rename_number);
      return syscall($rename_number, $from_fd, $from, $to_fd, $to, $exclusive_flag) == 0;
    }
    my $probe = eval { File::Temp::tempdir('.zshell-file-XXXXXXXX', DIR => '.', CLEANUP => 0) };
    my ($create, $rename) = (0, 0);
    if (defined($probe)) {
      push @cleanup, "$probe/a", "$probe/b", $probe;
      if (sysopen(my $first, "$probe/a", Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | $nofollow, 0600)) {
        close($first);
        $create = !sysopen(my $collision, "$probe/a", Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | $nofollow, 0600) && $!{EEXIST};
        if ($create && exclusive_rename(fileno($parent), "$probe/a", fileno($parent), "$probe/b")) {
          sysopen(my $second, "$probe/a", Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600) or fail('unavailable');
          close($second);
          $rename = !exclusive_rename(fileno($parent), "$probe/a", fileno($parent), "$probe/b") && $!{EEXIST};
        }
      }
    }
    if ($operation eq 'capabilities') {
      reply({capabilities => {create => $create ? JSON::PP::true() : JSON::PP::false(),
        rename => $rename ? JSON::PP::true() : JSON::PP::false(), trash => $rename ? JSON::PP::true() : JSON::PP::false(),
        save => $rename ? JSON::PP::true() : JSON::PP::false()}});
    }
    fail('unsafe') unless defined($leaf);
    if ($operation eq 'create' || $operation eq 'mkdir') {
      fail('unsupported') unless $create;
      if ($operation eq 'mkdir') { mkdir($leaf, 0777) or fail($!{EEXIST} ? 'collision' : 'unavailable'); }
      else { sysopen(my $new, $leaf, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | $nofollow, 0666)
          or fail($!{EEXIST} ? 'collision' : 'unavailable'); close($new) or fail('unavailable'); }
      reply({});
    }
    fail('unsupported') unless $rename;
    if ($operation eq 'save') {
      my $data = MIME::Base64::decode_base64($request->{data} // '');
      fail('large') if length($data) > 5 * 1024 * 1024;
      my $current = snapshot($leaf);
      reply({conflict => JSON::PP::true(), snapshot => $current}) unless matches($current, $request->{expected});
      fail('unsafe') unless $current->{kind} eq 'file' || $current->{kind} eq 'missing';
      reply({snapshot => $current}) if ($current->{data} // '') eq MIME::Base64::encode_base64($data, '') && $current->{kind} eq 'file';
      my ($temporary, $temporary_name) = File::Temp::tempfile('.zshell-file-XXXXXXXX', DIR => '.', UNLINK => 0);
      push @cleanup, $temporary_name;
      binmode($temporary);
      print {$temporary} $data or fail('unavailable');
      if ($current->{kind} eq 'file') {
        my @permissions = Time::HiRes::lstat($leaf);
        chmod($permissions[2] & 0777, $temporary) or fail('unavailable');
      }
      close($temporary) or fail('unavailable');
      my $latest = snapshot($leaf);
      reply({conflict => JSON::PP::true(), snapshot => $latest}) unless matches($latest, $current);
      if ($current->{kind} eq 'missing') {
        exclusive_rename(fileno($parent), $temporary_name, fileno($parent), $leaf)
          or fail($!{EEXIST} ? 'changed' : 'unsupported');
      } else { rename($temporary_name, $leaf) or fail('unavailable'); }
      my $written = snapshot($leaf);
      fail('changed') unless ($written->{data} // '') eq MIME::Base64::encode_base64($data, '');
      reply({snapshot => $written});
    }
    if ($operation eq 'rename') {
      my $name = bytes($request->{name} // '');
      fail('unsafe') unless name_ok($name);
      my @entry = Time::HiRes::lstat($leaf);
      fail('unsafe') unless @entry && (Fcntl::S_ISREG($entry[2]) || Fcntl::S_ISDIR($entry[2]));
      reply({}) if $name eq $leaf;
      exclusive_rename(fileno($parent), $leaf, fileno($parent), $name)
        or fail($!{EEXIST} ? 'collision' : 'unsupported');
      reply({});
    }
    my $parent_fd = fileno($parent);
    chdir($root) or fail('unsafe');
    if (!mkdir('.zshell-trash', 0700)) { fail('unsafe') unless $!{EEXIST}; }
    my $trash = open_directory('.zshell-trash');
    my @trash_stat = Time::HiRes::stat($trash);
    fail('unsafe') unless $trash_stat[4] == $< && ($trash_stat[2] & 0777) == 0700;
    if ($operation eq 'trash') {
      chdir($parent) or fail('unsafe');
      my @entry = Time::HiRes::lstat($leaf);
      fail('unsafe') unless @entry && (Fcntl::S_ISREG($entry[2]) || Fcntl::S_ISDIR($entry[2]));
      my $token = Digest::SHA::sha256_hex(bytes(join(':', $$, Time::HiRes::time(), rand(), $request->{path})));
      my $record = {original => $request->{path}, path => $token, root => $root_identity, identity => ident(\@entry)};
      chdir($trash) or fail('unsafe');
      sysopen(my $metadata, "$token.json", Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | $nofollow, 0600) or fail('unavailable');
      print {$metadata} $json->encode($record) or fail('unavailable');
      close($metadata) or fail('unavailable');
      unless (exclusive_rename($parent_fd, $leaf, fileno($trash), $token)) { unlink("$token.json"); fail('unsupported'); }
      reply({trash => $record});
    }
    if ($operation eq 'restore') {
      my $entry = $request->{trash};
      fail('unsafe') unless ref($entry) eq 'HASH' && $entry->{root} eq $root_identity && $entry->{path} =~ /^[a-f0-9]{64}$/;
      chdir($trash) or fail('unsafe');
      my @entry_stat = Time::HiRes::lstat($entry->{path});
      fail('changed') unless @entry_stat && ident(\@entry_stat) eq $entry->{identity};
      exclusive_rename(fileno($trash), $entry->{path}, $parent_fd, $leaf) or fail($!{EEXIST} ? 'collision' : 'unsupported');
      unlink($entry->{path} . '.json');
      reply({});
    }
    fail('unsupported');
    """#
}
