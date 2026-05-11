import SwiftUI
import WebKit

struct AuthView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @State private var showWebView = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("YTWatch")
                .font(.largeTitle.bold())

            Text("Sign in with your Google account to access your YouTube Music library.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button(action: { showWebView = true }) {
                Label("Sign in with Google", systemImage: "person.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .sheet(isPresented: $showWebView) {
            GoogleLoginSheet()
        }
    }
}

struct GoogleLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebLoginView { cookies in
                Task { @MainActor in
                    YTMusicClient.shared.saveCookies(cookies)
                    dismiss()
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct WebLoginView: UIViewRepresentable {
    var onLoginComplete: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onLoginComplete) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use the persistent shared store so Google recognises the session properly.
        // Non-persistent stores trigger Google's "disallowed_useragent" HTTP 400.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Impersonate Mobile Safari — Google blocks the default WKWebView UA.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: ([HTTPCookie]) -> Void
        private var didComplete = false

        init(onComplete: @escaping ([HTTPCookie]) -> Void) {
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didComplete,
                  let urlString = webView.url?.absoluteString,
                  // Only harvest once we've actually landed on the YT Music home page,
                  // not during intermediate auth redirects.
                  urlString.hasPrefix("https://music.youtube.com"),
                  !urlString.contains("/ServiceLogin"),
                  !urlString.contains("/signin") else { return }

            // Give the page a moment to set all cookies before harvesting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak webView] in
                guard let self, let webView else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let authCookies = cookies.filter {
                        $0.domain.hasSuffix(".youtube.com") || $0.domain.hasSuffix(".google.com")
                    }
                    guard !authCookies.isEmpty else { return }
                    self.didComplete = true
                    DispatchQueue.main.async { self.onComplete(authCookies) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Ignore cancellations (common during redirects)
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            print("WebView error: \(error.localizedDescription)")
        }
    }
}
