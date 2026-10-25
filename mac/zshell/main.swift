import SwiftUI

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

zshellApp.main()
