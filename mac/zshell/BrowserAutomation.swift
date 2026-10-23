//
//  BrowserAutomation.swift
//  zshell
//

import AppKit
import Foundation
import WebKit

struct BrowserAutomationError: Error {
    let code: String
    let message: String
}

/// A separate content world keeps page code out of element identity and command dispatch.
/// The only script input is data for the fixed operations below, never executable source.
@MainActor
final class BrowserAutomation {
    static let maximumTimeoutMS = 30_000
    static let maximumImageBytes = 524_288
    static let world = WKContentWorld.world(name: "sh.zshell.browser.automation")

    private(set) var restrictsNavigation = false
    private(set) var navigationWasRejected = false
    private(set) var documentRevision: UInt = 0
    var isBusy = false

    static func isAllowedURL(_ url: URL, isMainFrame: Bool = true) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        // srcdoc is an inline child document, not a top-level destination.
        if !isMainFrame, url.absoluteString == "about:srcdoc" { return true }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    static func destination(_ text: String) throws -> URL {
        guard text.utf8.count <= 8_192,
              let url = URL(string: text), isAllowedURL(url) else {
            throw BrowserAutomationError(
                code: "unsupported_url",
                message: "Browser automation requires an explicit HTTP or HTTPS URL, or about:blank, without embedded credentials."
            )
        }
        return url
    }

    func restrictNavigation() {
        restrictsNavigation = true
    }

    func resetNavigationError() { navigationWasRejected = false }

    func releaseNavigationRestriction() {
        restrictsNavigation = false
        navigationWasRejected = false
    }

    func rejectNavigation() {
        navigationWasRejected = true
    }

    func invalidateDocument() {
        documentRevision &+= 1
    }

    func perform(
        _ operation: String,
        in webView: WKWebView,
        params: [String: ZshellJSONValue],
        timeoutMS: Int,
        scopeIsValid: @escaping @MainActor () -> Bool
    ) async throws -> ZshellJSONValue {
        try checkPage(webView, scopeIsValid: scopeIsValid)
        restrictNavigation()
        let revision = documentRevision
        var arguments: [String: Any] = [
            "operation": operation,
            "revision": String(revision),
            "token": UUID().uuidString,
            "deadline": Date().timeIntervalSince1970 * 1_000 + Double(timeoutMS),
        ]
        for (key, value) in params {
            switch value {
            case .string(let string): arguments[key] = string
            case .number(let number): arguments[key] = number
            case .bool(let bool): arguments[key] = bool
            default: break
            }
        }
        let pending = BrowserAutomationPending<ZshellJSONValue>()
        let result = try await pending.run(timeoutMS: timeoutMS) { finish in
            webView.callAsyncJavaScript(
                Self.script, arguments: arguments, in: nil, in: Self.world
            ) { result in
                do {
                    let value = try result.get()
                    guard JSONSerialization.isValidJSONObject(value) else {
                        throw BrowserAutomationError(code: "invalid_response", message: "WebKit returned an invalid browser response.")
                    }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    guard data.count <= 262_144 else {
                        throw BrowserAutomationError(code: "response_too_large", message: "Browser DOM responses are limited to 256 KiB; request fewer elements or less text.")
                    }
                    finish(.success(try JSONDecoder().decode(ZshellJSONValue.self, from: data)))
                } catch {
                    finish(.failure(error))
                }
            }
        }
        try checkPage(webView, scopeIsValid: scopeIsValid)
        if operation == "snapshot", documentRevision != revision {
            throw BrowserAutomationError(code: "page_changed", message: "The page navigated while its snapshot was being read. Take a new snapshot.")
        }
        if let error = result.objectValue?["error"]?.objectValue,
           let code = error["code"]?.stringValue,
           let message = error["message"]?.stringValue {
            throw BrowserAutomationError(code: code, message: message)
        }
        return result
    }

    func screenshot(
        in webView: WKWebView,
        width: Int,
        timeoutMS: Int,
        scopeIsValid: @escaping @MainActor () -> Bool
    ) async throws -> ZshellJSONValue {
        try checkPage(webView, scopeIsValid: scopeIsValid)
        restrictNavigation()
        let revision = documentRevision
        let size = webView.bounds.size
        guard size.width >= 1, size.height >= 1,
              size.width <= 16_384, size.height <= 16_384 else {
            throw BrowserAutomationError(code: "browser_not_visible", message: "Show this browser pane once before taking a viewport screenshot.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: min(Double(width), Double(width) * size.width / size.height))
        let pending = BrowserAutomationPending<NSImage>()
        let image = try await pending.run(timeoutMS: timeoutMS) { finish in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    finish(.success(image))
                } else {
                    finish(.failure(error ?? BrowserAutomationError(code: "screenshot_failed", message: "WebKit could not capture this browser viewport.")))
                }
            }
        }
        try checkPage(webView, scopeIsValid: scopeIsValid)
        guard documentRevision == revision else {
            throw BrowserAutomationError(code: "page_changed", message: "The page navigated while its screenshot was being captured. Retry after it loads.")
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= Self.maximumImageBytes else {
            throw BrowserAutomationError(code: "screenshot_too_large", message: "PNG screenshots are limited to 512 KiB. Retry with a smaller --width.")
        }
        return .object([
            "format": .string("png"),
            "width": .number(Double(bitmap.pixelsWide)),
            "height": .number(Double(bitmap.pixelsHigh)),
            "bytes": .number(Double(png.count)),
            "data_base64": .string(png.base64EncodedString()),
        ])
    }

    private func checkPage(
        _ webView: WKWebView,
        scopeIsValid: @MainActor () -> Bool
    ) throws {
        guard scopeIsValid() else {
            throw BrowserAutomationError(code: "browser_scope_changed", message: "The caller or browser left the invoking project or window.")
        }
        guard let url = webView.url, Self.isAllowedURL(url) else {
            throw BrowserAutomationError(code: "unsupported_url", message: "Only HTTP, HTTPS, and about:blank pages can be automated.")
        }
    }

    private static let script = #"""
    const fail = (code, message) => ({error: {code, message}});
    if (Date.now() > deadline) return fail('browser_timeout', 'The browser operation expired before the page could execute it.');
    if (!globalThis.__zshellAutomation) {
      const state = {version: 0, refs: new Map(), snapshot: null};
      state.observer = new MutationObserver(() => { state.version++; state.refs.clear(); state.snapshot = null; });
      state.observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
      globalThis.__zshellAutomation = state;
    }
    const state = globalThis.__zshellAutomation;
    if (state.observer.takeRecords().length) { state.version++; state.refs.clear(); state.snapshot = null; }
    const text = (node, limit = 512) => {
      if (!node) return '';
      const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
      let value = '', count = 0, part;
      while ((part = walker.nextNode()) && count++ < 200 && value.length < limit) {
        if (!part.parentElement?.closest('script,style,noscript,template')) value += part.data.slice(0, limit - value.length) + ' ';
      }
      return value.replace(/\s+/g, ' ').trim().slice(0, limit);
    };
    const visible = el => {
      if (el.closest('[hidden],[inert],[aria-hidden="true"]')) return false;
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && style.visibility !== 'collapse' && style.display !== 'none' && el.getClientRects().length > 0;
    };
    const name = el => {
      const labelled = (el.getAttribute('aria-labelledby') || '').split(/\s+/).slice(0, 5)
        .map(id => text(document.getElementById(id), 128)).join(' ').trim();
      return (el.getAttribute('aria-label') || labelled || Array.from(el.labels || []).slice(0, 4).map(label => text(label, 128)).join(' ')
        || el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder') || text(el)).slice(0, 512);
    };
    const role = el => el.getAttribute('role') || ({A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', IMG: 'img', SUMMARY: 'button'}[el.tagName])
      || (el.tagName === 'INPUT' ? ({checkbox: 'checkbox', radio: 'radio', submit: 'button', button: 'button'}[el.type] || 'textbox') : (el.isContentEditable ? 'textbox' : el.tagName.toLowerCase()));
    const allowedURL = value => {
      try { const u = new URL(value, location.href); return u.href === 'about:blank' || (['http:', 'https:'].includes(u.protocol) && !u.username && !u.password); }
      catch { return false; }
    };
    const resolve = () => {
      if (typeof ref !== 'undefined') {
        const snapshot = state.snapshot;
        if (!snapshot || snapshot.revision !== revision || snapshot.version !== state.version || snapshot.url !== location.href) {
          return fail('stale_element_reference', 'The page changed. Take a new snapshot before using an element reference.');
        }
        const element = state.refs.get(ref);
        return element?.isConnected ? element : fail('stale_element_reference', 'The referenced element no longer exists. Take a new snapshot.');
      }
      try {
        const matches = document.querySelectorAll(selector);
        if (!matches.length) return fail('element_not_found', 'No element matches the selector.');
        if (matches.length !== 1) return fail('ambiguous_element', 'The selector matches more than one element. Use a unique selector or snapshot reference.');
        return matches[0];
      } catch { return fail('invalid_selector', 'The CSS selector is invalid.'); }
    };
    if (operation === 'snapshot') {
      state.refs.clear();
      state.snapshot = {revision, version: state.version, url: location.href};
      const elements = [], walker = document.createTreeWalker(document.documentElement || document, NodeFilter.SHOW_ELEMENT);
      let node, visited = 0, truncated = false;
      while ((node = walker.nextNode())) {
        if (++visited > 10000 || elements.length >= max_elements) { truncated = true; break; }
        if (!node.matches('a[href],button,input:not([type="hidden"]),textarea,select,summary,[role],h1,h2,h3,h4,h5,h6,[contenteditable="true"],[tabindex]') || !visible(node)) continue;
        const reference = token + ':' + elements.length;
        state.refs.set(reference, node);
        const entry = {ref: reference, tag: node.tagName.toLowerCase(), role: role(node), name: name(node), disabled: !!node.disabled || node.getAttribute('aria-disabled') === 'true'};
        if (node.id) entry.id = node.id.slice(0, 256);
        if (node.href) entry.href = String(node.href).slice(0, 2048);
        if (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') {
          entry.type = node.type;
          if (node.type !== 'password' && node.type !== 'file') entry.value = String(node.value).slice(0, 512);
          if (['checkbox', 'radio'].includes(node.type)) entry.checked = node.checked;
        }
        elements.push(entry);
      }
      let pageText = '', textNodes = 0;
      const texts = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT);
      while ((node = texts.nextNode())) {
        if (++textNodes > 10000 || pageText.length >= max_text) { truncated = true; break; }
        const parent = node.parentElement;
        if (parent && !parent.closest('script,style,noscript,template') && visible(parent)) pageText += node.data.slice(0, max_text - pageText.length) + ' ';
      }
      return {url: location.href.slice(0, 8192), title: document.title.slice(0, 512), ready_state: document.readyState, text: pageText.replace(/\s+/g, ' ').trim().slice(0, max_text), elements, truncated, frame_scope: 'main'};
    }
    if (operation === 'ready') return {ready: document.readyState !== 'loading', ready_state: document.readyState};
    const element = resolve();
    if (!(element instanceof Element)) return element;
    if (operation === 'wait') {
      return {matched: wait_state === 'attached' || visible(element), state: visible(element) ? 'visible' : 'attached'};
    }
    if (!visible(element)) return fail('element_not_visible', 'The target element is hidden.');
    if (element.disabled || element.getAttribute('aria-disabled') === 'true' || element.closest('[inert]')) return fail('element_disabled', 'The target element is disabled.');
    if (operation === 'click') {
      const link = element.closest('a[href],area[href]');
      if ((link && (!allowedURL(link.href) || link.hasAttribute('download'))) || element.matches('input[type="file"]')) {
        return fail('unsupported_action', 'External protocols, downloads, and file pickers require direct user interaction.');
      }
      if (typeof element.click !== 'function') return fail('unsupported_action', 'This element does not support clicking.');
      element.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
      element.click();
      state.refs.clear(); state.snapshot = null;
      return {clicked: true};
    }
    if (operation === 'fill') {
      if (element.readOnly) return fail('element_readonly', 'The target element is read-only.');
      if (element.matches('input[type="file"],input[type="hidden"],input[type="button"],input[type="submit"],input[type="reset"],input[type="checkbox"],input[type="radio"]')) return fail('unsupported_action', 'Use fill for editable text fields, textareas, selects, or contenteditable elements.');
      if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
        if (element instanceof HTMLSelectElement && !Array.from(element.options).some(option => option.value === value && !option.disabled)) return fail('invalid_value', 'No enabled select option has this value.');
        const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : element instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
      } else if (element.isContentEditable) element.textContent = value;
      else return fail('unsupported_action', 'The target element is not editable.');
      element.dispatchEvent(new Event('input', {bubbles: true}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
      state.refs.clear(); state.snapshot = null;
      return {filled: true};
    }
    return fail('unsupported_action', 'Unsupported browser operation.');
    """#
}

/// A WebKit callback can remain pending behind a modal or an unresponsive page.
/// Resolve once at the deadline without waiting for WebKit to cancel its work.
@MainActor
private final class BrowserAutomationPending<Value> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeoutMS: Int,
        start: (@escaping @MainActor (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(timeoutMS)) } catch { return }
                self?.finish(.failure(BrowserAutomationError(code: "browser_timeout", message: "The browser operation timed out. Inspect the pane for a dialog or an unresponsive page.")))
            }
            start { [self] in finish($0) }
        }
    }

    private func finish(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
