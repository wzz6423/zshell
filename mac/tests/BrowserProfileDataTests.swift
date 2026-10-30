import Foundation

@main
struct BrowserProfileDataTests {
    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        let found = BrowserProfileData.discover(home: home)
        precondition(found.blocked.isEmpty && found.profiles.count == 2)
        let chrome = found.profiles.first { $0.kind == .chrome }!
        let firefox = found.profiles.first { $0.kind == .firefox }!
        precondition(chrome.name == "Fixture Chrome" && firefox.name == "Fixture Firefox")
        let selection: BrowserProfileSelection = [.cookies, .history, .sessions]
        let first = BrowserProfileData.preview(chrome, selection: selection)
        precondition(first.cookieCount == 3 && first.cookieError == nil)
        precondition(first.history.total == 2 && first.history.values.count == 1 && first.history.skipped == 1)
        precondition(first.sessions.total == 2 && first.sessions.skipped == 1)
        precondition(first.sessions.values.map(\.url) == ["https://example.test/current"])
        let cookies = BrowserProfileData.cookies(chrome, password: Data("fixture-password".utf8))
        precondition(cookies.error == nil && cookies.total == 3 && cookies.skipped == 2 && cookies.values.count == 1)
        precondition(cookies.values[0].value == "fixture-only" && cookies.values[0].httpOnly)
        let wrongKey = BrowserProfileData.cookies(chrome, password: Data("incorrect".utf8))
        precondition(wrongKey.values.isEmpty && wrongKey.skipped == 3)
        let second = BrowserProfileData.preview(firefox, selection: selection)
        precondition(second.cookieCount == 4 && second.history.values.count == 1)
        precondition(second.sessions.total == 3 && second.sessions.skipped == 2)
        precondition(second.sessions.values.map(\.url) == ["https://example.test/two"])
        let firefoxCookies = BrowserProfileData.cookies(firefox)
        precondition(firefoxCookies.values.count == 2 && firefoxCookies.skipped == 2)
        precondition(firefoxCookies.values[0].sameSite == "Strict" && firefoxCookies.values[0].expires == 2_000_000_000)
        precondition(firefoxCookies.values[1].name == "session" && firefoxCookies.values[1].expires == -1)
        let bad = firefox.directory.appendingPathComponent("broken.jsonlz4")
        try Data("bad".utf8).write(to: bad)
        do { _ = try BrowserProfileSessionReader.firefox(bad); fatalError("Invalid LZ4 accepted") }
        catch BrowserProfileSessionReader.ReadError.invalidFile { }
        let invalidDirectory = home.appendingPathComponent("invalid-profile")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try Data("invalid SQLite".utf8).write(to: invalidDirectory.appendingPathComponent("cookies.sqlite"))
        let invalid = BrowserProfile(kind: .firefox, name: "Invalid", directory: invalidDirectory)
        precondition(BrowserProfileData.preview(invalid, selection: [.cookies, .sessions]).cookieError != nil)
        precondition(BrowserProfileData.cookies(invalid).error != nil)
        precondition(BrowserProfileData.preview(invalid, selection: [.sessions]).sessions.error != nil)
        print("Profile discovery, Chromium encryption/domain binding, partition skips, Firefox LZ4, history and sessions passed")
    }
}
