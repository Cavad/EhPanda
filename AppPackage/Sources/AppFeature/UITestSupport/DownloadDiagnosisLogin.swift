#if DEBUG && targetEnvironment(simulator)
import AppTools
import CookieClient
import OSLog
import SwiftUI
import WebKit

struct DownloadDiagnosisLogin: UIViewRepresentable {
    private static let logger = Logger(subsystem: "app.ehpanda.diagnosis", category: "sign-in")

    let username: String
    let password: String
    let onDone: @MainActor (Bool) -> Void

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: Defaults.URL.webLogin))
        Task { @MainActor in
            onDone(await signIn(view))
        }
        return view
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    private func signIn(_ view: WKWebView) async -> Bool {
        var submitted = false
        let cookieStore = view.configuration.websiteDataStore.httpCookieStore
        for _ in 0..<36 {
            let cookies = await cookieStore.allCookies()
            if importSession(cookies) {
                Self.logger.notice("DL_DIAG login_succeeded")
                return true
            }
            do {
                if !submitted, view.url?.host() == "forums.e-hentai.org", !view.isLoading {
                    submitted = try await submitForm(view)
                }
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return false
            } catch {
                Self.logger.notice("DL_DIAG login_failed reason=browser_script")
                return false
            }
        }
        Self.logger.notice("DL_DIAG login_failed form_submitted=\(submitted)")
        return false
    }

    private func importSession(_ cookies: [HTTPCookie]) -> Bool {
        let forumDomains = [".e-hentai.org", "e-hentai.org", "forums.e-hentai.org"]
        let siteCookies = cookies.filter({ forumDomains.contains($0.domain) })
        guard let memberID = siteCookies.first(where: { $0.name == Defaults.Cookie.ipbMemberId })?.value,
              let passHash = siteCookies.first(where: { $0.name == Defaults.Cookie.ipbPassHash })?.value,
              !memberID.isEmpty, !passHash.isEmpty, memberID != "0", passHash != "0"
        else { return false }
        CookieClient.live.importAutomationCookies(memberID: memberID, passHash: passHash, igneous: nil)
        return true
    }

    private func submitForm(_ view: WKWebView) async throws -> Bool {
        let result = try await view.callAsyncJavaScript(
            """
            if (location.origin !== 'https://forums.e-hentai.org') return false;
            const user = document.querySelector('input[name="UserName"]');
            const pass = document.querySelector('input[name="PassWord"]');
            const submit = document.querySelector('[name="ipb_login_submit"]');
            const form = user?.form;
            if (!form || pass?.form !== form || submit?.form !== form ||
                new URL(form.action).origin !== location.origin) return false;
            user.value = username;
            pass.value = password;
            submit.click();
            return true;
            """,
            arguments: ["username": username, "password": password],
            in: nil,
            contentWorld: .page
        )
        return result as? Bool == true
    }
}
#endif
