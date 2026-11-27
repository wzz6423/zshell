import SwiftUI

if RemoteSessionRelay.shouldRun {
    RemoteSessionRelay.run()
}

if PTYMuxCommandLine.shouldRunChild {
    PTYMuxCommandLine.runChild()
}

if PTYMuxCommandLine.shouldRunRelay {
    PTYMuxRelay.run()
}

if PTYMuxCommandLine.shouldRunDaemon {
    PTYMuxCommandLine.runDaemon()
}

if ZshellCommandLine.shouldRun {
    ZshellCommandLine.main()
}

// A GUI launched from a Zshell pane owns its own mux. Only the CLI and PTY
// helpers above may follow the parent pane's connection across app builds.
if getenv("ZSHELL_TERMINAL_ID") != nil {
    unsetenv("ZSHELL_PTY_MUX_DIRECTORY")
    unsetenv("ZSHELL_PERSISTENT_CONNECTION")
    unsetenv("ZSHELL_PERSISTENT_TOKEN")
}

zshellApp.main()
