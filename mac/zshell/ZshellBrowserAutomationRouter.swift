//
//  ZshellBrowserAutomationRouter.swift
//  zshell
//

import Foundation
import WebKit

extension ZshellAutomationRouter {
    static func routeBrowser(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) async -> ZshellAutomationResponse {
        do {
            let result = try await browserResult(request, caller: caller)
            guard try JSONEncoder().encode(result).count <= 900_000 else {
                throw browserError("response_too_large", "The browser response exceeds the local protocol limit.")
            }
            return .success(id: request.id, result: result)
        } catch let error as BrowserAutomationError {
            return .failure(id: request.id, code: error.code, message: error.message)
        } catch {
            return .failure(id: request.id, code: "browser_error", message: String(error.localizedDescription.prefix(1_024)))
        }
    }

    private static func browserResult(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) async throws -> ZshellJSONValue {
        let params = request.params
        if request.method == "browser.list" {
            return .array(browserContexts(caller).map(browserSnapshot))
        }
        if request.method == "browser.open" {
            return try openBrowser(request, caller: caller)
        }
        let methods: Set<String> = [
            "browser.get", "browser.navigate", "browser.back", "browser.forward", "browser.reload", "browser.stop",
            "browser.snapshot", "browser.click", "browser.fill", "browser.wait", "browser.screenshot",
        ]
        guard methods.contains(request.method) else {
            throw browserError("method_not_found", "Unknown browser automation method.")
        }
        let target = try targetBrowser(params, caller: caller)
        guard case .browser(let browser) = target.pane.content else {
            throw browserError("browser_not_found", "No matching browser exists in this project.")
        }
        if request.method == "browser.get" { return browserSnapshot(target) }
        guard !browser.automation.isBusy else {
            throw browserError("browser_busy", "Another operation is active in this browser. Wait for it to finish.")
        }
        let timeout = try browserInteger(params, "timeout_ms", default: 5_000, range: 100...BrowserAutomation.maximumTimeoutMS)
        guard let terminalID = caller.session?.id else {
            throw browserError("caller_closed", "The invoking terminal is no longer open.")
        }
        let scopeIsValid: @MainActor () -> Bool = {
            guard let current = context(forSession: terminalID),
                  current.manager === caller.manager, current.project === caller.project,
                  current.project.tabs.contains(where: { $0 === target.tab }),
                  target.tab.allPanes.contains(where: { $0.id == target.pane.id && $0.content.browser === browser }),
                  browser.belongs(to: caller.manager) else { return false }
            return true
        }
        guard scopeIsValid() else {
            throw browserError("browser_scope_changed", "The caller or browser left the invoking project or window.")
        }
        browser.automation.isBusy = true
        defer { browser.automation.isBusy = false }
        let operation = String(request.method.dropFirst("browser.".count))
        switch operation {
        case "navigate", "back", "forward", "reload", "stop":
            var url: URL?
            if operation == "navigate" {
                guard let address = params["url"]?.stringValue else {
                    throw browserError("invalid_params", "url is required.")
                }
                url = try BrowserAutomation.destination(address)
            } else if operation != "stop" {
                guard let currentURL = browser.webView.url, BrowserAutomation.isAllowedURL(currentURL) else {
                    throw browserError("unsupported_url", "Only HTTP, HTTPS, and about:blank pages can be automated.")
                }
                let historyURL = operation == "back" ? browser.webView.backForwardList.backItem?.url
                    : operation == "forward" ? browser.webView.backForwardList.forwardItem?.url : browser.webView.url
                guard let historyURL, BrowserAutomation.isAllowedURL(historyURL) else {
                    throw browserError("navigation_unavailable", "No allowed page exists in that history direction.")
                }
            }
            browser.automationNavigate(operation, url: url)
            return browserSnapshot(target)

        case "snapshot":
            try requireLoaded(browser)
            var options: [String: ZshellJSONValue] = [:]
            options["max_elements"] = .number(Double(try browserInteger(params, "max_elements", default: 100, range: 1...200)))
            options["max_text"] = .number(Double(try browserInteger(params, "max_text", default: 16_384, range: 1...32_768)))
            let result = try await browser.automation.perform(operation, in: browser.webView, params: options, timeoutMS: timeout, scopeIsValid: scopeIsValid)
            return browserEnvelope(result, target: target)

        case "click", "fill":
            try requireLoaded(browser)
            var options = try browserElementTarget(params)
            if operation == "fill" {
                guard let value = params["value"]?.stringValue, value.utf8.count <= 65_536 else {
                    throw browserError("invalid_params", "value is required and is limited to 64 KiB.")
                }
                options["value"] = .string(value)
            }
            browser.automation.resetNavigationError()
            let result = try await browser.automation.perform(operation, in: browser.webView, params: options, timeoutMS: timeout, scopeIsValid: scopeIsValid)
            return browserEnvelope(result, target: target)

        case "wait":
            var options: [String: ZshellJSONValue] = [:]
            let hasElement = params["selector"] != nil || params["ref"] != nil
            if hasElement { options = try browserElementTarget(params) }
            let state = params["state"]?.stringValue ?? "visible"
            guard ["attached", "visible"].contains(state) else {
                throw browserError("invalid_params", "state must be attached or visible.")
            }
            options["wait_state"] = .string(state)
            let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
            repeat {
                guard scopeIsValid() else {
                    throw browserError("browser_scope_changed", "The caller or browser left the invoking project or window.")
                }
                if browser.automation.navigationWasRejected {
                    throw browserError("unsupported_url", "The page attempted a blocked protocol or download. Inspect the browser pane.")
                }
                if let error = browser.errorMessage {
                    throw browserError("navigation_failed", String(error.prefix(1_024)))
                }
                if !browser.webView.isLoading {
                    let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
                    do {
                        let result = try await browser.automation.perform(hasElement ? "wait" : "ready", in: browser.webView, params: options, timeoutMS: remaining, scopeIsValid: scopeIsValid)
                        if result.objectValue?[hasElement ? "matched" : "ready"]?.boolValue == true {
                            return browserEnvelope(result, target: target)
                        }
                    } catch let error as BrowserAutomationError where error.code == "element_not_found" {
                        // A missing element is the expected intermediate state of a bounded wait.
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < deadline
            throw browserError("browser_timeout", "Timed out waiting for the browser or requested element.")

        case "screenshot":
            try requireLoaded(browser)
            let width = try browserInteger(params, "width", default: 1_024, range: 64...1_600)
            let result = try await browser.automation.screenshot(in: browser.webView, width: width, timeoutMS: timeout, scopeIsValid: scopeIsValid)
            return browserEnvelope(result, target: target)
        default:
            throw browserError("method_not_found", "Unknown browser operation.")
        }
    }

    private static func openBrowser(
        _ request: ZshellAutomationRequest,
        caller: PaneContext
    ) throws -> ZshellJSONValue {
        let params = request.params
        if let value = params["url"], value.stringValue == nil {
            throw browserError("invalid_params", "url must be a string.")
        }
        let address = params["url"]?.stringValue ?? "about:blank"
        let url = try BrowserAutomation.destination(address)
        let focus = params["focus"]?.boolValue ?? false
        let asTab = params["tab"]?.boolValue ?? false
        for key in ["focus", "tab"] where params[key] != nil && params[key]?.boolValue == nil {
            throw browserError("invalid_params", "\(key) must be a Boolean.")
        }
        let contexts = projectContexts(caller.project, manager: caller.manager)
        let beside: PaneContext
        if let paneValue = params["pane_id"] {
            guard let raw = paneValue.stringValue, let id = UUID(uuidString: raw),
                  let context = contexts.first(where: { $0.pane.id == id }) else {
                throw browserError("pane_not_found", "No matching pane exists in this project.")
            }
            beside = context
        } else { beside = caller }
        let browser: BrowserTab
        if asTab {
            browser = caller.project.newBrowserTab(initialFocus: .none, focus: focus)
        } else {
            let edgeName = params["edge"]?.stringValue ?? "right"
            let edge: PaneDropEdge
            switch edgeName {
            case "left": edge = .left
            case "right": edge = .right
            case "top": edge = .top
            case "bottom": edge = .bottom
            default: throw browserError("invalid_params", "edge must be left, right, top, or bottom.")
            }
            guard let created = caller.project.newBrowserPane(toward: edge, initialFocus: .none, beside: beside.pane.id, focus: focus) else {
                throw browserError("pane_not_splittable", "The target pane could not be split.")
            }
            browser = created
        }
        browser.automationNavigate("navigate", url: url)
        if focus { caller.manager.selectedProjectID = caller.project.id }
        guard let context = browserContexts(caller).first(where: { $0.pane.content.browser === browser }) else {
            throw browserError("browser_not_found", "The created browser is unavailable.")
        }
        return browserSnapshot(context)
    }

    private static func browserContexts(_ caller: PaneContext) -> [PaneContext] {
        projectContexts(caller.project, manager: caller.manager).filter { $0.pane.content.browser != nil }
    }

    private static func targetBrowser(_ params: [String: ZshellJSONValue], caller: PaneContext) throws -> PaneContext {
        let contexts = browserContexts(caller)
        guard params["browser_id"] == nil || params["pane_id"] == nil else {
            throw browserError("invalid_params", "Choose browser_id or pane_id, not both.")
        }
        if let value = params["browser_id"] ?? params["pane_id"] {
            guard let raw = value.stringValue, let id = UUID(uuidString: raw),
                  let context = contexts.first(where: {
                      params["browser_id"] != nil ? $0.pane.content.browser?.id == id : $0.pane.id == id
                  }) else {
                throw browserError("browser_not_found", "No matching browser exists in this project.")
            }
            return context
        }
        guard contexts.count == 1, let context = contexts.first else {
            throw browserError("browser_target_required", "Pass --browser or --pane unless the project has exactly one browser.")
        }
        return context
    }

    private static func browserElementTarget(_ params: [String: ZshellJSONValue]) throws -> [String: ZshellJSONValue] {
        let keys = ["ref", "selector"].filter { params[$0] != nil }
        guard keys.count == 1, let key = keys.first,
              let value = params[key]?.stringValue, !value.isEmpty,
              value.utf8.count <= (key == "ref" ? 128 : 4_096) else {
            throw browserError("invalid_params", "Choose exactly one non-empty ref (up to 128 bytes) or selector (up to 4 KiB).")
        }
        return [key: .string(value)]
    }

    private static func requireLoaded(_ browser: BrowserTab) throws {
        guard !browser.webView.isLoading else {
            throw browserError("page_loading", "The page is loading. Use +browser wait before interacting with it.")
        }
    }

    private static func browserInteger(_ params: [String: ZshellJSONValue], _ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[name] else { return fallback }
        guard let number = value.intValue, range.contains(number) else {
            throw browserError("invalid_params", "\(name) must be an integer between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }

    private static func browserEnvelope(_ result: ZshellJSONValue, target: PaneContext) -> ZshellJSONValue {
        var object = result.objectValue ?? [:]
        let browser = browserSnapshot(target)
        object["browser"] = browser
        object["browser_id"] = browser.objectValue?["browser_id"]
        object["pane_id"] = .string(target.pane.id.uuidString)
        return .object(object)
    }

    private static func browserSnapshot(_ context: PaneContext) -> ZshellJSONValue {
        guard let browser = context.pane.content.browser else { return .null }
        return .object([
            "browser_id": .string(browser.id.uuidString),
            "project_id": .string(context.project.id.uuidString),
            "tab_id": .string(context.tab.id.uuidString),
            "pane_id": .string(context.pane.id.uuidString),
            "title": .string(String(browser.title.prefix(512))),
            "url": .string(String(browser.urlString.prefix(8_192))),
            "is_loading": .bool(browser.webView.isLoading),
            "can_go_back": .bool(browser.canGoBack),
            "can_go_forward": .bool(browser.canGoForward),
            "navigation_blocked": .bool(browser.automation.navigationWasRejected),
            "is_focused": .bool(context.manager.selectedProjectID == context.project.id && context.project.selectedTabID == context.tab.id && context.tab.focusedPaneID == context.pane.id),
        ])
    }

    private static func browserError(_ code: String, _ message: String) -> BrowserAutomationError {
        BrowserAutomationError(code: code, message: message)
    }
}

private extension PaneContent {
    @MainActor var browser: BrowserTab? {
        guard case .browser(let browser) = self else { return nil }
        return browser
    }
}
