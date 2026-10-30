import Foundation

enum TerminalShellCompletions {
    static var resourceDirectory: URL? {
        guard let directory = Bundle.main.resourceURL?
            .appendingPathComponent("ShellIntegration/TerminalCompletions", isDirectory: true),
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("init.zsh").path)
        else { return nil }
        return directory
    }

    static func configure(_ files: inout [String: String]) {
        guard AppSettings.shared.shellCompletions, let resources = resourceDirectory,
              let startup = files[".zshrc"] else { return }
        let prefix = """
        # 在用户的 compinit 之前追加，保留用户已有 completer 的优先级。
        fpath+=(\(quote(resources.appendingPathComponent("completions").path)))
        """
        files[".zshrc"] = prefix + "\n" + startup + "\nsource "
            + quote(resources.appendingPathComponent("init.zsh").path) + "\n"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
