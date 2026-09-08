import AppKit
import WebKit

/// A retained local WebKit renderer shared by preview, SVG export, and PNG export.
@MainActor
final class FlowchartPreview: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var isReady = false
    private var loadingError: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Installed bundles contain a direct resource directory; SwiftPM runs use the module bundle.
    static func resourceRoot() throws -> URL {
        if let installed = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "Flowchart") {
            return installed.deletingLastPathComponent()
        }
        guard let page = Bundle.module.url(forResource: "renderer", withExtension: "html", subdirectory: "Flowchart") else {
            throw FlowchartError.message("找不到流程图模板资源，请重新构建应用。")
        }
        return page.deletingLastPathComponent()
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        do {
            let root = try Self.resourceRoot()
            webView.loadFileURL(root.appendingPathComponent("renderer.html"), allowingReadAccessTo: root)
        } catch {
            loadingError = error
        }
    }

    /// Initialize packaged geometry once; the unmodified reference's unrelated text/fonts are unused.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                let root = try Self.resourceRoot()
                let names = ["file-text", "cpu", "code", "settings", "link", "play", "check"]
                var icons: [String: String] = [:]
                for name in names {
                    icons[name] = try String(contentsOf: root.appendingPathComponent("icons/\(name).svg"), encoding: .utf8)
                }
                let staircase = try String(contentsOf: root.appendingPathComponent("staircase-reference.svg"), encoding: .utf8)
                _ = try await webView.callAsyncJavaScript(
                    "window.FlowchartRenderer.initialize(resources); await document.fonts.ready; return true;",
                    arguments: ["resources": ["icons": icons, "staircase": staircase]], in: nil, contentWorld: .page
                )
                finishLoading(error: nil)
            } catch {
                finishLoading(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error: error)
    }

    private func finishLoading(error: Error?) {
        loadingError = error
        isReady = error == nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func ready() async throws {
        if let loadingError { throw loadingError }
        if isReady { return }
        try await withCheckedThrowingContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }

    /// JSON serialization and structured WebKit arguments prevent text from becoming executable code.
    @discardableResult
    func render(_ document: FlowchartDocument, style: FlowchartStyle) async throws -> [String: Any] {
        try await ready()
        let data = try JSONEncoder().encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        let result = try await webView.callAsyncJavaScript("return window.FlowchartRenderer.render(diagram, style);",
            arguments: ["diagram": object, "style": style.rawValue], in: nil, contentWorld: .page)
        return result as? [String: Any] ?? [:]
    }

    func setZoom(_ scale: Double?) async throws {
        try await ready()
        _ = try await webView.callAsyncJavaScript("window.FlowchartRenderer.setZoom(scale);",
            arguments: ["scale": scale as Any? ?? NSNull()], in: nil, contentWorld: .page)
    }

    /// Export the full document, not a screenshot of the currently visible preview rectangle.
    func svgData() async throws -> Data {
        try await ready()
        let result = try await webView.callAsyncJavaScript("return window.FlowchartRenderer.serialize();",
            arguments: [:], in: nil, contentWorld: .page)
        guard let svg = result as? String, !svg.isEmpty, let data = svg.data(using: .utf8) else {
            throw FlowchartError.message("当前没有可导出的流程图。")
        }
        return data
    }

    func pngData(longEdge: Int) async throws -> Data {
        try await ready()
        let result = try await webView.callAsyncJavaScript("return await window.FlowchartRenderer.exportPNG(longEdge);",
            arguments: ["longEdge": longEdge], in: nil, contentWorld: .page)
        guard let object = result as? [String: Any], let encoded = object["data"] as? String,
              let data = Data(base64Encoded: encoded) else {
            throw FlowchartError.message("PNG 导出失败，请重新生成预览后再试。")
        }
        return data
    }
}
