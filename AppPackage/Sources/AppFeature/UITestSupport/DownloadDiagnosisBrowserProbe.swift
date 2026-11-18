#if DEBUG && targetEnvironment(simulator)
import AppLaunchAutomationClient
import AppTools
import OSLog
import SwiftUI
import WebKit

struct DownloadDiagnosisBrowserProbe: UIViewRepresentable {
    private static let logger = Logger(subsystem: "app.ehpanda.diagnosis", category: "browser")

    static let viewerPaths = [
        "/s/32776809a6/4133615-4", "/s/52ace716b0/4133615-20",
        "/s/2440766e27/4133615-36", "/s/8a2139139c/4133615-87"
    ]

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        Task { @MainActor in
            await probe(view)
        }
        return view
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    private func probe(_ view: WKWebView) async {
        guard let session = AppLaunchAutomation.current?.loginCookies, let igneous = session.igneous else {
            Self.logger.notice("DL_DIAG browser_done session=false")
            return
        }
        let storage = view.configuration.websiteDataStore.httpCookieStore
        let values = [
            Defaults.Cookie.ipbMemberId: session.memberID,
            Defaults.Cookie.ipbPassHash: session.passHash,
            Defaults.Cookie.igneous: igneous
        ]
        for (name, value) in values {
            if let cookie = HTTPCookie(properties: [
                .name: name, .value: value, .domain: "exhentai.org", .path: "/", .secure: "TRUE"
            ]) {
                await storage.setCookie(cookie)
            }
        }
        for path in Self.viewerPaths {
            guard let url = URL(string: "https://exhentai.org\(path)"),
                  let page = path.split(separator: "-").last.flatMap({ Int($0) })
            else { continue }
            let began = Date()
            let loaded = await loadImage(in: view, viewer: url)
            let milliseconds = Int(Date().timeIntervalSince(began) * 1000)
            Self.logger.notice("DL_DIAG browser page=\(page) loaded=\(loaded) milliseconds=\(milliseconds)")
        }
        Self.logger.notice("DL_DIAG browser_done session=true")
    }

    private func loadImage(in view: WKWebView, viewer: URL) async -> Bool {
        view.load(URLRequest(url: viewer))
        for _ in 0..<90 {
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard view.url?.path == viewer.path else { continue }
                let output = try await view.callAsyncJavaScript(
                    """
                    const image = document.querySelector('#i3 img');
                    return Boolean(image?.complete && image.naturalWidth > 0);
                    """,
                    contentWorld: .page
                )
                if output as? Bool == true { return true }
            } catch is CancellationError {
                return false
            } catch {
                continue
            }
        }
        view.stopLoading()
        return false
    }
}
#endif
