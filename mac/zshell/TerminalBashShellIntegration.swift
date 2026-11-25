import Foundation
import Darwin

nonisolated enum TerminalBashShellIntegration {
    static func inputIsClean(promptSequence: UInt64, inputSequence: UInt64?) -> Bool {
        inputSequence.map { promptSequence > max(1, $0) } ?? true
    }

    static func readPromptSequence(shellPID: pid_t, directory: URL) -> UInt64? {
        guard let sequence = readSequence(shellPID: shellPID, directory: directory, name: "command-task-ready.pid"),
            sequence > 0
        else { return nil }
        return sequence
    }

    static func persistentInputIsClean(shellPID: pid_t, directory: URL, promptSequence: UInt64) -> Bool {
        let file = directory.appendingPathComponent("command-task-input.pid")
        var metadata = stat()
        if lstat(file.path, &metadata) != 0 { return errno == ENOENT }
        guard let sequence = readSequence(shellPID: shellPID, directory: directory, name: file.lastPathComponent) else { return false }
        return inputIsClean(promptSequence: promptSequence, inputSequence: sequence)
    }

    static func recordPersistentInput(shellPID: pid_t, directory: URL, inputSequence: UInt64? = nil) -> Bool {
        let sequence = inputSequence ?? readPromptSequence(shellPID: shellPID, directory: directory) ?? 0
        let file = directory.appendingPathComponent("command-task-input.pid")
        do {
            try Data("\(shellPID):\(sequence)\n".utf8).write(to: file, options: .atomic)
            return true
        } catch { return false }
    }

    private static func readSequence(shellPID: pid_t, directory: URL, name: String) -> UInt64? {
        let file = directory.appendingPathComponent(name)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            let data = try? handle.read(upToCount: 257), data.count <= 256,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard fields.count == 2, pid_t(fields[0]) == shellPID, let sequence = UInt64(fields[1]) else { return nil }
        return sequence
    }

    static func interactiveArguments(_ argv: [String]) -> Bool {
        guard let executable = argv.first, executable.hasPrefix("/"),
            (executable as NSString).lastPathComponent == "bash"
        else { return false }
        return argv.dropFirst().allSatisfy { argument in
            argument.hasPrefix("-") && argument.count > 1
                && argument.dropFirst().allSatisfy { $0 == "i" || $0 == "l" }
        }
    }

    static func bootstrap(in directory: URL, initialization: String?) -> String {
        let file = directory.appendingPathComponent("bash-integration/bashrc")
        let command =
            "if [ \"$$\" = \"$ZSHELL_BASH_BOOTSTRAP_PID\" ]; then "
            + "builtin source \(quote(file.path)); fi"
        return "export ZSHELL_BASH_BOOTSTRAP_PID=\"$$\"; "
            + "export ZSHELL_BASH_BOOTSTRAP=\(quote(command)); "
            + "export ZSHELL_BASH_INIT_COMMAND=\(quote(initialization ?? "")); "
            + "export PROMPT_COMMAND=\"$ZSHELL_BASH_BOOTSTRAP${PROMPT_COMMAND:+; $PROMPT_COMMAND}\""
    }

    static func makeArtifacts(in directory: URL) throws -> URL {
        let integration = directory.appendingPathComponent("bash-integration", isDirectory: true)
        try FileManager.default.createDirectory(
            at: integration, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = integration.appendingPathComponent("bashrc")
        try script(in: directory).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return integration
    }

    static func script(in directory: URL) -> String {
        let tasks = quote(directory.appendingPathComponent("command-tasks", isDirectory: true).path)
        let ready = quote(directory.appendingPathComponent("command-task-ready.pid").path)
        return #"""
            [[ $- == *i* && -t 0 && -t 1 && $$ == "$ZSHELL_BASH_BOOTSTRAP_PID" && ${BASH_SUBSHELL:-0} == 0 ]] || return
            builtin shopt -q promptvars || return
            builtin shopt -q extdebug && return
            [[ ${_zshell_bash_owner:-} == "$$" ]] && return
            _zshell_bash_owner=$$
            _zshell_bash_prompt_sequence=0
            _zshell_bash_command_active=0
            _zshell_bash_task_id=''
            # A login file may chain the inherited hook. Remove only our bootstrap,
            # retaining the user's command and its original evaluation order.
            if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
              for _zshell_bash_index in "${!PROMPT_COMMAND[@]}"; do
                PROMPT_COMMAND[_zshell_bash_index]=${PROMPT_COMMAND[_zshell_bash_index]//"$ZSHELL_BASH_BOOTSTRAP"/:}
              done
              unset _zshell_bash_index
            else
              PROMPT_COMMAND=${PROMPT_COMMAND//"$ZSHELL_BASH_BOOTSTRAP"/:}
            fi
            export -n PROMPT_COMMAND
            _zshell_bash_initialization=${ZSHELL_BASH_INIT_COMMAND:-}
            unset ZSHELL_BASH_BOOTSTRAP_PID ZSHELL_BASH_BOOTSTRAP ZSHELL_BASH_INIT_COMMAND

            _zshell_bash_urlencode() {
              local LC_ALL=C _zshell_character _zshell_byte _zshell_index
              REPLY=''
              for ((_zshell_index=0; _zshell_index < ${#1}; _zshell_index++)); do
                _zshell_character=${1:_zshell_index:1}
                case "$_zshell_character" in
                  [a-zA-Z0-9/._~-]) REPLY=$REPLY$_zshell_character ;;
                  *) builtin printf -v _zshell_byte '%%%02X' "'$_zshell_character"; REPLY=$REPLY$_zshell_byte ;;
                esac
              done
            }
            _zshell_bash_task_result() {
              [[ -n $_zshell_bash_task_id ]] || return
              local _zshell_status=$1 _zshell_elapsed=-1 _zshell_now
              if [[ -n ${EPOCHREALTIME:-} && $_zshell_bash_task_start != 0 ]]; then
                _zshell_now=${EPOCHREALTIME/./}
                _zshell_elapsed=$(( (_zshell_now - _zshell_bash_task_start) * 1000 ))
                (( _zshell_elapsed < 0 )) && _zshell_elapsed=0
              fi
              (umask 077; builtin printf '1\t%s\t%s\t%s\t%s\n' \
                "$_zshell_bash_task_id" "$$" "$_zshell_status" "$_zshell_elapsed" \
                >| \#(tasks)/"$_zshell_bash_task_id.part" && \
                /bin/mv -f -- \#(tasks)/"$_zshell_bash_task_id.part" \#(tasks)/"$_zshell_bash_task_id.result")
              _zshell_bash_task_id=''
              _zshell_bash_command_active=0
              builtin printf '\e]133;D;%s\a' "$_zshell_status"
            }
            _zshell_command_task() {
              [[ $$ == "$_zshell_bash_owner" && ${BASH_SUBSHELL:-0} == 0 ]] || return 1
              builtin shopt -q extdebug && return 1
              _zshell_bash_task_id=$1
              shift
              _zshell_bash_command_active=1
              local REPLY
              _zshell_bash_urlencode "$PWD"
              builtin printf '\e]7;file://localhost%s\a\e]133;C\a' "$REPLY"
              _zshell_bash_task_start=${EPOCHREALTIME:-0}
              _zshell_bash_task_start=${_zshell_bash_task_start/./}
              local _zshell_status
              if "$@"; then _zshell_status=0; else _zshell_status=$?; fi
              _zshell_bash_task_result "$_zshell_status"
              return "$_zshell_status"
            }
            _zshell_bash_precmd() {
              local _zshell_status=$?
              if [[ $$ == "$_zshell_bash_owner" && ${BASH_SUBSHELL:-0} == 0 ]] && (( _zshell_bash_command_active )); then
                # Bash aborts the function body on Ctrl-C. The first prompt still
                # owns that task's status and publishes the same atomic result.
                _zshell_bash_task_result "$_zshell_status"
              fi
              return "$_zshell_status"
            }
            _zshell_bash_prompt() {
              local _zshell_status=$?
              [[ $$ == "$_zshell_bash_owner" && ${BASH_SUBSHELL:-0} == 0 ]] || return "$_zshell_status"
              local _zshell_start=$'\[\e]133;A\a\]' _zshell_end=$'\[\e]133;B\a\]'
              [[ $PS1 == "$_zshell_start"* ]] && PS1=${PS1#"$_zshell_start"}
              [[ $PS1 == *"$_zshell_end" ]] && PS1=${PS1%"$_zshell_end"}
              PS1=$_zshell_start$PS1$_zshell_end
              ((_zshell_bash_prompt_sequence++))
              builtin shopt -q extdebug && return "$_zshell_status"
              (umask 077; builtin printf '%s:%s\n' "$$" "$_zshell_bash_prompt_sequence" >| \#(ready))
              return "$_zshell_status"
            }
            if [[ -n $_zshell_bash_initialization ]]; then
              builtin eval -- "$_zshell_bash_initialization" || builtin printf 'zshell: initialization command failed (%s)\n' "$?" >&2
            fi
            unset _zshell_bash_initialization
            if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* && ${BASH_VERSINFO[0]} -ge 4 ]]; then
              PROMPT_COMMAND=(_zshell_bash_precmd "${PROMPT_COMMAND[@]}" _zshell_bash_prompt)
            else
              PROMPT_COMMAND[0]="_zshell_bash_precmd; ${PROMPT_COMMAND[0]:-:}; _zshell_bash_prompt"
            fi
            _zshell_bash_prompt
            """#
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
