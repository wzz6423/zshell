import SwiftUI

if PTYMuxCommandLine.shouldRunDaemon {
    PTYMuxCommandLine.runDaemon()
}

if ZshellCommandLine.shouldRun {
    ZshellCommandLine.main()
}

zshellApp.main()
