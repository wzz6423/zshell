import Foundation

nonisolated struct TerminalNextCommandNotificationRequest: Equatable, Sendable {
    let id: UUID
    let shellPID: pid_t
    let integrationID: UUID

    static func integrationID(in directory: URL, shellPID: pid_t) -> UUID? {
        guard let fields = readFields(directory.appendingPathComponent("command-notification-ready")),
            fields.count == 3, fields[0] == "1", pid_t(fields[1]) == shellPID
        else { return nil }
        return UUID(uuidString: String(fields[2]))
    }

    func arm(in directory: URL) throws {
        let file = directory.appendingPathComponent("next-command-notification.request")
        try PersistentCLIConnection.writePrivate(Data("1\t\(shellPID)\t\(integrationID.uuidString)\t\(id.uuidString)\n".utf8), to: file)
    }

    func result(in directory: URL) -> (command: TerminalCommandNotificationResult, message: String)? {
        guard let fields = Self.readFields(directory.appendingPathComponent("next-command-notification.result")),
            fields.count == 7, fields[0] == "1", pid_t(fields[1]) == shellPID,
            UUID(uuidString: String(fields[2])) == integrationID, UUID(uuidString: String(fields[3])) == id,
            let sequence = UInt64(fields[4]), sequence > 0,
            let exitCode = Int(fields[5]), (0 ... 255).contains(exitCode),
            !fields[6].isEmpty, fields[6].utf8.count <= 512,
            !fields[6].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return (.init(id: integrationID, sequence: sequence, exitCode: exitCode), String(fields[6]))
    }

    static func clear(in directory: URL) {
        for name in ["next-command-notification.request", "next-command-notification.result", "next-command-notification.part"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func readFields(_ file: URL) -> [Substring]? {
        guard let data = try? PersistentCLIConnection.readPrivate(file, maximumBytes: 768),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
    }
}

enum TerminalCommandNotificationShellIntegration {
    static func script(in directory: URL, finishSeconds: Int, onError: Bool) -> String {
        let ready = quote(directory.appendingPathComponent("command-notification-ready").path)
        let request = quote(directory.appendingPathComponent("next-command-notification.request").path)
        let result = quote(directory.appendingPathComponent("next-command-notification.result").path)
        let part = quote(directory.appendingPathComponent("next-command-notification.part").path)
        return """


            _zshell_notify_seconds=\(finishSeconds)
            _zshell_notify_on_error=\(onError ? 1 : 0)
            _zshell_notify_stamp=0
            _zshell_notify_word=''
            _zshell_notify_id='\(UUID().uuidString)'
            _zshell_notify_pid=$$
            _zshell_notify_sequence=0
            _zshell_notify_active=''
            _zshell_notify_consumed=''
            zmodload -i zsh/datetime 2>/dev/null
            if (( $+EPOCHSECONDS )); then
              _zshell_notify_request() {
                [[ -f \(request) ]] || return 1
                local _zshell_notify_version _zshell_notify_owner _zshell_notify_session _zshell_notify_token
                IFS=$'\\t' builtin read -r _zshell_notify_version _zshell_notify_owner _zshell_notify_session _zshell_notify_token \
                  2>/dev/null < \(request) || return 1
                [[ $_zshell_notify_version == 1 && $_zshell_notify_owner == $$ \
                  && $_zshell_notify_session == $_zshell_notify_id \
                  && ${#_zshell_notify_token} == 36 && $_zshell_notify_token != *[^[:xdigit:]-]* ]] || return 1
                REPLY=$_zshell_notify_token
              }
              _zshell_notify_preexec() {
                local _zshell_notify_prev=$?
                (( ZSH_SUBSHELL == 0 && $$ == _zshell_notify_pid )) || return $_zshell_notify_prev
                _zshell_notify_stamp=$EPOCHSECONDS
                local -a _zshell_notify_words
                _zshell_notify_words=(${(z)1})
                _zshell_notify_word=${_zshell_notify_words[1]}
                _zshell_notify_active=''
                local _zshell_notify_first=$_zshell_notify_word
                local _zshell_notify_index=1
                while [[ $_zshell_notify_first == builtin || $_zshell_notify_first == command ]]; do
                  (( ++_zshell_notify_index ))
                  _zshell_notify_first=${_zshell_notify_words[_zshell_notify_index]}
                done
                if [[ $_zshell_notify_first == exec || $_zshell_notify_first == exit || $_zshell_notify_first == logout ]]; then
                  /bin/rm -f -- \(ready) \(request)
                  return $_zshell_notify_prev
                fi
                local REPLY
                if _zshell_notify_request && [[ $REPLY != $_zshell_notify_consumed ]]; then
                  _zshell_notify_active=$REPLY
                  _zshell_notify_consumed=$REPLY
                fi
                return $_zshell_notify_prev
              }
              _zshell_notify_precmd() {
                local _zshell_notify_status=$?
                (( ZSH_SUBSHELL == 0 && $$ == _zshell_notify_pid )) || return $_zshell_notify_status
                if (( _zshell_notify_stamp )); then
                  local _zshell_notify_elapsed=$(( EPOCHSECONDS - _zshell_notify_stamp ))
                  (( _zshell_notify_elapsed < 0 )) && _zshell_notify_elapsed=0
                  _zshell_notify_stamp=0
                  local _zshell_notify_fire=0
                  if (( _zshell_notify_seconds > 0 && _zshell_notify_elapsed >= _zshell_notify_seconds \
                      || _zshell_notify_on_error && _zshell_notify_status != 0 )); then
                    _zshell_notify_fire=1
                  fi
                  if (( _zshell_notify_fire )) || [[ -n $_zshell_notify_active ]]; then
                    # A command word is untrusted terminal text; keep it bounded
                    # and strip the notification and result-file delimiters.
                    local _zshell_notify_name=${_zshell_notify_word//[[:cntrl:];]/}
                    _zshell_notify_name=${_zshell_notify_name[1,64]}
                    [[ -n $_zshell_notify_name || -z $_zshell_notify_active ]] || _zshell_notify_name=command
                    if [[ -n $_zshell_notify_name ]]; then
                      local _zshell_notify_outcome=finished
                      (( _zshell_notify_status != 0 )) && _zshell_notify_outcome=failed
                      local _zshell_notify_message="$_zshell_notify_name $_zshell_notify_outcome — ${_zshell_notify_elapsed}s, exit $_zshell_notify_status"
                      (( ++_zshell_notify_sequence ))
                      local REPLY
                      if [[ -n $_zshell_notify_active ]] && _zshell_notify_request && [[ $REPLY == $_zshell_notify_active ]]; then
                        # One immutable result survives rapid commands and the
                        # backend's desktop-notification throttle. The automatic
                        # notification below shares its event identity.
                        (umask 077; builtin printf '1\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \
                          "$$" "$_zshell_notify_id" "$_zshell_notify_active" "$_zshell_notify_sequence" \
                          "$_zshell_notify_status" "$_zshell_notify_message" >| \(part) \
                          && /bin/mv -f -- \(part) \(result))
                      fi
                      if (( _zshell_notify_fire )); then
                        builtin printf '\\e]777;notify;zshell-command:%s:%s:%s;%s\\e\\\\' \
                          "$_zshell_notify_id" "$_zshell_notify_sequence" "$_zshell_notify_status" "$_zshell_notify_message"
                      fi
                    fi
                  fi
                  _zshell_notify_active=''
                fi
                return $_zshell_notify_status
              }
              _zshell_notify_exit() {
                (( ZSH_SUBSHELL == 0 && $$ == _zshell_notify_pid )) || return
                /bin/rm -f -- \(ready) \(request)
              }
              add-zsh-hook preexec _zshell_notify_preexec
              # Read the command's exit before prompt frameworks replace `$?`.
              precmd_functions=(_zshell_notify_precmd ${precmd_functions:#_zshell_notify_precmd})
              add-zsh-hook zshexit _zshell_notify_exit
              (umask 077; builtin printf '1\\t%s\\t%s\\n' "$$" "$_zshell_notify_id" >| \(ready))
            fi
            """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
