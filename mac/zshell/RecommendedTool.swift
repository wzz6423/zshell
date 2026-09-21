//
//  RecommendedTool.swift
//  zshell
//

import Foundation

nonisolated enum RecommendedToolGroup: CaseIterable, Sendable {
    case terminalEfficiency, networkAndData, developmentToolchain, utility, desktopApplication

    var title: String {
        switch self {
        case .terminalEfficiency: String(localized: "Terminal Efficiency")
        case .networkAndData: String(localized: "Network and Data")
        case .developmentToolchain: String(localized: "Development Toolchain")
        case .utility: String(localized: "Utilities")
        case .desktopApplication: String(localized: "Desktop Applications")
        }
    }
}

nonisolated enum RecommendedTool: String, CaseIterable, Sendable {
    case fzf
    case ripgrep
    case delta
    case lazygit
    case githubCLI
    case neovim
    case yazi
    case starship
    case tldr
    case jq
    case tree
    case curl
    case wget
    case rclone
    case posting
    case poppler
    case wireshark
    case mysql
    case cmake
    case gnuMake
    case ninja
    case gcc
    case go
    case rust
    case nodeJS
    case deno
    case python
    case ruby
    case openJDK17
    case maven
    case groovy
    case cocoaPods
    case pyenv
    case pipx
    case uv
    case pnpm
    case tectonic
    case packer
    case ytt
    case ytDLP
    case libreOffice
    case keka
    case kaku
    case kero
    case markdownPreview
    case zshell

    var name: String {
        switch self {
        case .fzf: "fzf"
        case .ripgrep: "ripgrep"
        case .delta: "delta"
        case .lazygit: "lazygit"
        case .githubCLI: "GitHub CLI"
        case .neovim: "Neovim"
        case .yazi: "Yazi"
        case .starship: "Starship"
        case .tldr: "tldr"
        case .jq: "jq"
        case .tree: "tree"
        case .curl: "curl"
        case .wget: "wget"
        case .rclone: "rclone"
        case .posting: "Posting"
        case .poppler: "Poppler"
        case .wireshark: "Wireshark"
        case .mysql: "MySQL"
        case .cmake: "CMake"
        case .gnuMake: "GNU Make"
        case .ninja: "Ninja"
        case .gcc: "GCC"
        case .go: "Go"
        case .rust: "Rust"
        case .nodeJS: "Node.js"
        case .deno: "Deno"
        case .python: "Python"
        case .ruby: "Ruby"
        case .openJDK17: "OpenJDK 17"
        case .maven: "Maven"
        case .groovy: "Groovy"
        case .cocoaPods: "CocoaPods"
        case .pyenv: "pyenv"
        case .pipx: "pipx"
        case .uv: "uv"
        case .pnpm: "pnpm"
        case .tectonic: "Tectonic"
        case .packer: "Packer"
        case .ytt: "ytt"
        case .ytDLP: "yt-dlp"
        case .libreOffice: "LibreOffice"
        case .keka: "Keka"
        case .kaku: "Kaku"
        case .kero: "Kero"
        case .markdownPreview: "Markdown Preview"
        case .zshell: "Zshell"
        }
    }

    var purpose: String {
        switch self {
        case .fzf: String(localized: "Fuzzy finder")
        case .ripgrep: String(localized: "Fast text search")
        case .delta: String(localized: "Git diff highlighting")
        case .lazygit: String(localized: "Visual Git interface")
        case .githubCLI: String(localized: "GitHub command-line management")
        case .neovim: String(localized: "Modern editor")
        case .yazi: String(localized: "Terminal file manager")
        case .starship: String(localized: "Cross-shell prompt")
        case .tldr: String(localized: "Simplified command manuals")
        case .jq: String(localized: "JSON processing")
        case .tree: String(localized: "Directory tree display")
        case .curl: String(localized: "Network requests")
        case .wget: String(localized: "File downloads")
        case .rclone: String(localized: "Cloud storage sync")
        case .posting: String(localized: "Terminal API client")
        case .poppler: String(localized: "PDF processing tools")
        case .wireshark: String(localized: "Network packet analysis")
        case .mysql: String(localized: "Relational database and client")
        case .cmake: String(localized: "Cross-platform build configuration")
        case .gnuMake: String(localized: "GNU build tool")
        case .ninja: String(localized: "Fast build system")
        case .gcc: String(localized: "GNU compiler collection")
        case .go: String(localized: "Go development toolchain")
        case .rust: String(localized: "Rust development toolchain")
        case .nodeJS: String(localized: "JavaScript runtime")
        case .deno: String(localized: "JavaScript and TypeScript runtime")
        case .python: String(localized: "Python runtime")
        case .ruby: String(localized: "Ruby runtime")
        case .openJDK17: String(localized: "Java 17 development toolchain")
        case .maven: String(localized: "Java builds and dependencies")
        case .groovy: String(localized: "JVM dynamic language")
        case .cocoaPods: String(localized: "Apple platform dependency management")
        case .pyenv: String(localized: "Python version management")
        case .pipx: String(localized: "Isolated Python CLI installs")
        case .uv: String(localized: "Python packages and projects")
        case .pnpm: String(localized: "Node.js package management")
        case .tectonic: String(localized: "Modern TeX typesetting engine")
        case .packer: String(localized: "Machine image builds")
        case .ytt: String(localized: "YAML templates")
        case .ytDLP: String(localized: "Video and audio downloads")
        case .libreOffice: String(localized: "Office to PDF conversion")
        case .keka: String(localized: "Archive compression and extraction")
        case .kaku: String(localized: "Terminal for AI coding")
        case .kero: String(localized: "Terminal workspace")
        case .markdownPreview: String(localized: "Markdown preview")
        case .zshell: String(localized: "Native macOS terminal workspace")
        }
    }

    var executableName: String {
        switch self {
        case .fzf: "fzf"
        case .ripgrep: "rg"
        case .delta: "delta"
        case .lazygit: "lazygit"
        case .githubCLI: "gh"
        case .neovim: "nvim"
        case .yazi: "yazi"
        case .starship: "starship"
        case .tldr: "tldr"
        case .jq: "jq"
        case .tree: "tree"
        case .curl: "curl"
        case .wget: "wget"
        case .rclone: "rclone"
        case .posting: "posting"
        case .poppler: "pdftotext"
        case .wireshark: "tshark"
        case .mysql: "mysql"
        case .cmake: "cmake"
        case .gnuMake: "gmake"
        case .ninja: "ninja"
        case .gcc: "gcc"
        case .go: "go"
        case .rust: "rustc"
        case .nodeJS: "node"
        case .deno: "deno"
        case .python: "python3"
        case .ruby: "ruby"
        case .openJDK17: "java"
        case .maven: "mvn"
        case .groovy: "groovy"
        case .cocoaPods: "pod"
        case .pyenv: "pyenv"
        case .pipx: "pipx"
        case .uv: "uv"
        case .pnpm: "pnpm"
        case .tectonic: "tectonic"
        case .packer: "packer"
        case .ytt: "ytt"
        case .ytDLP: "yt-dlp"
        case .libreOffice: "soffice"
        case .keka: "keka"
        case .kaku: "kaku"
        case .kero: "kero"
        case .markdownPreview: "mdp"
        case .zshell: "zshell"
        }
    }

    var packageName: String? {
        switch self {
        case .fzf: "fzf"
        case .ripgrep: "ripgrep"
        case .delta: "git-delta"
        case .lazygit: "lazygit"
        case .githubCLI: "gh"
        case .neovim: "neovim"
        case .yazi: "yazi"
        case .starship: "starship"
        case .tldr: "tldr"
        case .jq: "jq"
        case .tree: "tree"
        case .curl: "curl"
        case .wget: "wget"
        case .rclone: "rclone"
        case .posting: "posting"
        case .poppler: "poppler"
        case .wireshark: "wireshark"
        case .mysql: "mysql"
        case .cmake: "cmake"
        case .gnuMake: "make"
        case .ninja: "ninja"
        case .gcc: "gcc"
        case .go: "go"
        case .rust: "rust"
        case .nodeJS: "node"
        case .deno: "deno"
        case .python: "python"
        case .ruby: "ruby"
        case .openJDK17: "openjdk@17"
        case .maven: "maven"
        case .groovy: "groovy"
        case .cocoaPods: "cocoapods"
        case .pyenv: "pyenv"
        case .pipx: "pipx"
        case .uv: "uv"
        case .pnpm: "pnpm"
        case .tectonic: "tectonic"
        case .packer: "hashicorp/tap/packer"
        case .ytt: "ytt"
        case .ytDLP: "yt-dlp"
        case .libreOffice: "libreoffice"
        case .keka: "keka"
        case .kaku: "tw93/tap/kakuku"
        case .kero: "egoist/tap/kero"
        case .markdownPreview: "markdown-preview"
        case .zshell: nil
        }
    }

    var isCask: Bool {
        switch self {
        case .libreOffice, .keka, .kaku, .kero, .markdownPreview: true
        default: false
        }
    }

    var brewFlag: String { isCask ? "--cask" : "--formula" }

    var requiredTap: String? {
        guard let parts = packageName?.split(separator: "/"), parts.count == 3 else { return nil }
        return parts.prefix(2).joined(separator: "/")
    }

    var group: RecommendedToolGroup {
        switch self {
        case .fzf, .ripgrep, .delta, .lazygit, .githubCLI, .neovim, .yazi, .starship, .tldr, .jq, .tree:
            .terminalEfficiency
        case .curl, .wget, .rclone, .posting, .poppler, .wireshark, .mysql:
            .networkAndData
        case .cmake, .gnuMake, .ninja, .gcc, .go, .rust, .nodeJS, .deno, .python, .ruby,
             .openJDK17, .maven, .groovy, .cocoaPods, .pyenv, .pipx, .uv, .pnpm, .tectonic, .packer, .ytt:
            .developmentToolchain
        case .ytDLP, .libreOffice, .keka:
            .utility
        case .kaku, .kero, .markdownPreview, .zshell:
            .desktopApplication
        }
    }

    var applicationName: String? {
        switch self {
        case .libreOffice: "LibreOffice"
        case .keka: "Keka"
        case .kaku: "Kaku"
        case .kero: "Kero"
        case .markdownPreview: "Markdown Preview"
        default: nil
        }
    }

    var versionArguments: [String] {
        switch self {
        case .go: ["version"]
        case .poppler: ["-v"]
        default: ["--version"]
        }
    }

    var metadataURL: URL? {
        guard let packageName else { return nil }
        // Read the tap's recipe so an upstream release cannot advertise an
        // update that Homebrew cannot install yet. Never execute this Ruby.
        let source: String
        switch self {
        case .python:
            // Contents follows the official alias as Homebrew changes Python's
            // default series, unlike the formula API which only accepts its name.
            source = "https://api.github.com/repos/Homebrew/homebrew-core/contents/Aliases/python?ref=HEAD"
        case .packer:
            source = "https://api.github.com/repos/hashicorp/homebrew-tap/contents/Formula/packer.rb?ref=main"
        case .kaku:
            source = "https://api.github.com/repos/tw93/homebrew-tap/contents/Casks/kakuku.rb?ref=main"
        case .kero:
            source = "https://api.github.com/repos/egoist/homebrew-tap/contents/Casks/kero.rb?ref=main"
        default:
            source = "https://formulae.brew.sh/api/\(isCask ? "cask" : "formula")/\(packageName).json"
        }
        return URL(string: source)
    }
}
