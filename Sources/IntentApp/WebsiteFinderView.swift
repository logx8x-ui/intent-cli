import AppKit
import SwiftUI
import WebKit
import IntentCore

/// Deliberately a small independent website finder, not an embedded Firefox or
/// Chrome profile. It never opens a destination or mutates the chosen browser.
@MainActor
final class WebsiteFinderController: ObservableObject {
    let target: WebsiteFinderTarget
    @Published var query = ""
    @Published private(set) var status: String?
    @Published private(set) var loading = false
    @Published private(set) var searchGeneration = UUID()
    @Published private(set) var hasSearch = false
    private(set) var webView: WKWebView
    private var navigationDelegate: WebsiteFinderNavigationDelegate?
    private var capture: WebsiteFinderCapture
    private let currentTarget: () -> WebsiteFinderTarget?
    private let onCapture: (WebsiteFinderTarget, URL) -> Void

    init(target: WebsiteFinderTarget, currentTarget: @escaping () -> WebsiteFinderTarget?,
         onCapture: @escaping (WebsiteFinderTarget, URL) -> Void) {
        self.target = target
        self.currentTarget = currentTarget
        self.onCapture = onCapture
        capture = WebsiteFinderCapture(target: target)
        webView = Self.makeWebView()
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WebsiteFinderWebSurface(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        return view
    }

    func submit() {
        guard currentTarget() == target, target.isValid, !capture.cancelled, capture.destination == nil else {
            cancel(); status = "The browser selection changed. Open the finder again."; return
        }
        switch WebsiteFinderPolicy.submission(query) {
        case .invalid:
            status = "Enter a search or a complete http or https website address."
        case .destination(let url):
            choose(url)
        case .search(let url):
            // A new web view gives every search its own callback generation.
            // Stopped/reordered replies cannot capture for a newer query.
            webView.stopLoading(); webView.navigationDelegate = nil
            searchGeneration = UUID()
            webView = Self.makeWebView()
            let delegate = WebsiteFinderNavigationDelegate(owner: self, generation: searchGeneration)
            navigationDelegate = delegate
            webView.navigationDelegate = delegate
            hasSearch = true; loading = true; status = nil
            webView.load(URLRequest(url: url))
        }
    }

    func cancel() {
        capture.cancel()
        webView.stopLoading(); webView.navigationDelegate = nil
        navigationDelegate = nil; loading = false
    }

    fileprivate func isCurrent(_ generation: UUID) -> Bool {
        generation == searchGeneration && currentTarget() == target && !capture.cancelled && capture.destination == nil
    }

    fileprivate func choose(_ url: URL) {
        guard let destination = capture.take(url, currentTarget: currentTarget()) else { return }
        webView.stopLoading(); webView.navigationDelegate = nil
        navigationDelegate = nil; loading = false
        onCapture(target, destination)
    }

    fileprivate func finishLoading(generation: UUID, error: Error? = nil) {
        guard isCurrent(generation) else { return }
        loading = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            status = "Search is unavailable. Try again, or enter the website address directly."
        }
    }

    fileprivate func unsupportedNavigation(generation: UUID) {
        guard isCurrent(generation) else { return }
        loading = false
        status = "This link cannot be added here. Enter the website address directly."
    }
}

@MainActor
private final class WebsiteFinderNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: WebsiteFinderController?
    let generation: UUID
    init(owner: WebsiteFinderController, generation: UUID) { self.owner = owner; self.generation = generation }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { decisionHandler(.cancel); return }
            self.decide(action, decisionHandler: decisionHandler)
        }
    }

    private func decide(_ action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let owner, owner.isCurrent(generation) else { decisionHandler(.cancel); return }
        let result = WebsiteFinderPolicy.navigation(to: action.request.url,
            userClickedLink: action.navigationType == .linkActivated,
            topLevel: action.targetFrame?.isMainFrame ?? action.sourceFrame.isMainFrame,
            download: action.shouldPerformDownload)
        switch result {
        case .search:
            decisionHandler(.allow)
        case .destination(let url):
            // Cancel before handing ownership to the parent. No destination
            // request is issued by this preview, including target=_blank links.
            decisionHandler(.cancel)
            owner.choose(url)
        case .cancel:
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame ?? action.sourceFrame.isMainFrame {
                owner.unsupportedNavigation(generation: generation)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { decisionHandler(.cancel); return }
            self.decide(response, decisionHandler: decisionHandler)
        }
    }

    private func decide(_ response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard owner?.isCurrent(generation) == true, response.isForMainFrame,
              let url = response.response.url, WebsiteFinderPolicy.isSearchPage(url),
              response.canShowMIMEType, response.response.mimeType == "text/html" else {
            decisionHandler(.cancel)
            owner?.unsupportedNavigation(generation: generation)
            return
        }
        decisionHandler(.allow)
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in guard let self else { return }; owner?.finishLoading(generation: generation) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in guard let self else { return }; owner?.finishLoading(generation: generation, error: error) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in guard let self else { return }; owner?.finishLoading(generation: generation, error: error) }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            owner?.finishLoading(generation: generation, error: NSError(domain: "WebsiteFinder", code: 1))
        }
    }
}

private final class WebsiteFinderWebSurface: WKWebView {
    // Keep Open in New Window/Download context-menu actions from bypassing the
    // finder’s one explicit result-click route.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

struct WebsiteFinderView: View {
    @ObservedObject var controller: WebsiteFinderController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("Add a website to \(controller.target.browserName)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { controller.cancel(); onClose() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Close website finder")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                WebsiteFinderAddressInput(controller: controller)
                    .frame(minHeight: 18)
                if controller.loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Button { controller.submit() } label: { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Find website")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(0.07), in: Capsule())
            if controller.hasSearch {
                WebsiteFinderWebView(controller: controller).id(controller.searchGeneration)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 23, weight: .light))
                    Text("Search, then choose a website.").font(.system(size: 13, weight: .medium))
                    Text("It won’t open inside this preview.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(controller.status ?? "DuckDuckGo search · separate from browser sign-ins")
                    .font(.system(size: 10)).foregroundStyle(controller.status == nil ? .secondary : .primary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .onDisappear { controller.cancel() }
    }
}

/// AppKit attachment, rather than SwiftUI appearance, owns the one initial
/// first-responder request. Appearance can fire before the field has a window,
/// leaving the overview's optional-name field in possession of typing.
final class WebsiteFinderAddressField: NSTextField, NSTextFieldDelegate {
    private weak var finder: WebsiteFinderController?
    private var attachment = UUID()
    private var initialFocusPending = true
    private var focusScheduled = false

    init(controller: WebsiteFinderController) {
        finder = controller
        super.init(frame: .zero)
        stringValue = controller.query
        placeholderString = "Search or enter a website"
        isBordered = false; drawsBackground = false
        isEditable = true; isSelectable = true
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Website address or search")
        delegate = self
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachment = UUID(); focusScheduled = false
        requestInitialFocus()
    }

    func updateQuery() {
        guard let finder, (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if stringValue != finder.query { stringValue = finder.query }
        requestInitialFocus()
    }

    func requestInitialFocus() {
        guard initialFocusPending, !focusScheduled, window != nil else { return }
        focusScheduled = true
        let expectedAttachment = attachment
        DispatchQueue.main.async { [weak self] in
            guard let self, attachment == expectedAttachment else { return }
            focusScheduled = false
            guard initialFocusPending, let finder,
                  finder.isCurrent(finder.searchGeneration),
                  let window, window.isVisible, window.isKeyWindow,
                  window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return }
            // Never activate the app, raise a window, or follow the user to a
            // different app. This only transfers typing inside the current UI.
            if window.makeFirstResponder(self) { initialFocusPending = false }
        }
    }

    func invalidatePendingFocus() {
        attachment = UUID(); initialFocusPending = false; focusScheduled = false
    }

    func controlTextDidBeginEditing(_ notification: Notification) { initialFocusPending = false }
    func controlTextDidChange(_ notification: Notification) {
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        finder?.query = stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard command == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        finder?.query = stringValue
        finder?.submit()
        return true
    }
}

private struct WebsiteFinderAddressInput: NSViewRepresentable {
    let controller: WebsiteFinderController
    func makeNSView(context: Context) -> WebsiteFinderAddressField { WebsiteFinderAddressField(controller: controller) }
    func updateNSView(_ nsView: WebsiteFinderAddressField, context: Context) { nsView.updateQuery() }
    static func dismantleNSView(_ nsView: WebsiteFinderAddressField, coordinator: ()) { nsView.invalidatePendingFocus() }
}

private struct WebsiteFinderWebView: NSViewRepresentable {
    let controller: WebsiteFinderController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) { nsView.stopLoading(); nsView.navigationDelegate = nil }
}
