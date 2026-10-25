import Foundation

struct TerminalCommandTaskShellResult {
    let taskID: UUID
    let exitCode: Int
    let durationNanos: UInt64?

    static func read(taskID: UUID, shellPID: pid_t, directory: URL) -> Self? {
        let file = directory.appendingPathComponent(taskID.uuidString + ".result")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 257), data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "1",
              UUID(uuidString: String(fields[1])) == taskID,
              pid_t(fields[2]) == shellPID,
              let exitCode = Int(fields[3]), (0...255).contains(exitCode) else { return nil }
        return Self(
            taskID: taskID, exitCode: exitCode,
            durationNanos: UInt64(fields[4])
        )
    }
}

enum TerminalCommandTaskShellIntegration {
    static func script(in directory: URL) -> String {
        let tasks = quote(directory.appendingPathComponent("command-tasks", isDirectory: true).path)
        let ready = quote(directory.appendingPathComponent("command-task-ready.pid").path)
        return """


        zmodload -i zsh/datetime 2>/dev/null
        _zshell_command_task() {
          setopt localoptions noerrexit noerrreturn
          local _zshell_task_id=$1
          shift
          local _zshell_task_start=${EPOCHREALTIME:-0}
          # Alacritty's preexec already emitted C; Ghostty may have no
          # injected hooks when its launcher is the sh proxy.
          [[ "$ZSHELL_TERM" == alacritty ]] || builtin print -n $'\\e]133;C\\a'
          local _zshell_task_status
          local _zshell_task_returned=0
          {
            "$@"
            _zshell_task_status=$?
            _zshell_task_returned=1
          } always {
            local _zshell_cleanup_status=$?
            if (( _zshell_task_returned || _zshell_cleanup_status == 130 )); then
              (( _zshell_task_returned )) || _zshell_task_status=$_zshell_cleanup_status
              local -i _zshell_task_elapsed=-1
              if (( _zshell_task_start > 0 )); then
                _zshell_task_elapsed=$(( (EPOCHREALTIME - _zshell_task_start) * 1000000000 ))
                (( _zshell_task_elapsed < 0 )) && _zshell_task_elapsed=0
              fi
              # Publish once and atomically, including Ctrl-C, before prompt
              # hooks or unrelated child jobs can change the exit status.
              (umask 077; builtin printf '1\\t%s\\t%s\\t%s\\t%s\\n' \
                "$_zshell_task_id" "$$" "$_zshell_task_status" "$_zshell_task_elapsed" \
                >| \(tasks)/"$_zshell_task_id.part" && \
                /bin/mv -f -- \(tasks)/"$_zshell_task_id.part" \(tasks)/"$_zshell_task_id.result")
              _zshell_command_active=0
              builtin printf '\\e]133;D;%s\\a' "$_zshell_task_status"
            fi
          }
          return $_zshell_task_status
        }
        builtin print -r -- "$$" >| \(ready)
        # Ghostty already injects these hooks. Only the Alacritty path needs
        # them here, or a single command would be reported twice.
        if [[ "$ZSHELL_TERM" == alacritty ]]; then
          _zshell_command_active=0
          _zshell_command_preexec() {
            local _zshell_command_previous=$?
            _zshell_command_active=1
            builtin print -n $'\\e]133;C\\a'
            return $_zshell_command_previous
          }
          _zshell_command_precmd() {
            local _zshell_command_status=$?
            if (( _zshell_command_active )); then
              _zshell_command_active=0
              builtin printf '\\e]133;D;%s\\a' "$_zshell_command_status"
            fi
            return $_zshell_command_status
          }
          preexec_functions=(_zshell_command_preexec ${preexec_functions:#_zshell_command_preexec})
          precmd_functions=(_zshell_command_precmd ${precmd_functions:#_zshell_command_precmd})
        fi
        """
    }

    static func replacesOriginalShell(_ argv: [String]) -> Bool {
        var index = 0
        while index < argv.count, argv[index] == "builtin" { index += 1 }
        guard index < argv.count else { return false }
        return ["exit", "logout", "exec"].contains(argv[index])
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
