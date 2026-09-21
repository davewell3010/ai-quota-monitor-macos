import AppKit
import WebKit

@MainActor
final class ClaudeWeb: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var window: NSWindow?
    var organizations: [(id: String, name: String)] = []
    private var loaded = false
    private var loading = false
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func showLogin() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.contentView = webView; w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.title = UserDefaults.standard.string(forKey: "displayLanguage") == AppLanguage.english.rawValue
            ? "Connect Claude · Sign in on the official site, then refresh the card"
            : "连接 Claude · 请在官方网站登录，完成后点击卡片刷新"
        loaded = false; loading = false
        loadIfNeeded()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func loadIfNeeded() {
        guard !loading && !loaded else { return }
        loading = true
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false }
    func read() async throws -> QuotaSnapshot {
        guard loaded else { loadIfNeeded(); throw QuotaError.message("首次使用请点击「连接 Claude」登录；登录后刷新。") }
        guard webView.url?.host == "claude.ai" else { throw QuotaError.message("请完成 Claude 登录后再刷新。") }
        let script = """
        if (location.hostname !== 'claude.ai') throw new Error('请完成 Claude 登录');
        async function get(path) {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 12000);
          try {
            const response = await fetch(path, {credentials: 'include', signal: controller.signal});
            if (response.status === 401 || response.status === 403) throw new Error('登录已失效或需要网页验证，请点击连接 Claude');
            if (response.status === 429) throw new Error('请求较频繁，请稍后再试');
            if (!response.ok) throw new Error('Claude 服务暂时不可用（' + response.status + '）');
            return await response.json();
          } finally { clearTimeout(timer); }
        }
        const organizations = await get('/api/organizations');
        if (!Array.isArray(organizations) || !organizations.length) throw new Error('未找到 Claude 账号');
        const choices = organizations.map(o => ({id:o.uuid, name:o.name || '个人账号'}));
        const chosen = choices.find(o => o.id === organizationID) || (choices.length === 1 ? choices[0] : null);
        if (!chosen) return {organizations:choices, needsSelection:true};
        const usage = await get('/api/organizations/' + encodeURIComponent(chosen.id) + '/usage');
        return {organizations:choices, usage:usage};
        """
        let object = try await webView.callAsyncJavaScript(script, arguments: ["organizationID": UserDefaults.standard.string(forKey: "claudeOrg") ?? ""], in: nil, contentWorld: .page)
        guard let value = object as? [String: Any] else { throw QuotaError.message("Claude 返回了无法识别的数据。") }
        if let choices = value["organizations"] as? [[String: Any]] {
            organizations = choices.compactMap { row in guard let id = row["id"] as? String else { return nil }; return (id, row["name"] as? String ?? "个人账号") }
        }
        if value["needsSelection"] as? Bool == true { throw QuotaError.message("发现多个 Claude 组织，请在设置里选择账号。") }
        return try QuotaParser.claude(value["usage"] as? [String: Any] ?? [:])
    }
    func logout() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        loaded = false; loading = false; organizations = []
        webView.stopLoading()
    }
}
