import SwiftUI
import WebKit

// Full-screen Google login via WKWebView — captures auth cookies on success.
struct AuthView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @State private var showWebView = false
    @State private var checking = false

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
    @State private var url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!

    var body: some View {
        NavigationStack {
            WebLoginView(url: $url) { cookies in
                let ytCookies = cookies.filter {
                    $0.domain.contains("youtube") || $0.domain.contains("google")
                }
                Task { @MainActor in
                    YTMusicClient.shared.saveCookies(ytCookies)
                }
                dismiss()
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
    @Binding var url: URL
    var onLoginComplete: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onLoginComplete) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Fresh cookie store so we capture exactly what this login produces
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: ([HTTPCookie]) -> Void

        init(onComplete: @escaping ([HTTPCookie]) -> Void) {
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url?.absoluteString,
                  url.contains("music.youtube.com") else { return }

            // We landed on YT Music — harvest cookies
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                DispatchQueue.main.async {
                    self.onComplete(cookies)
                }
            }
        }
    }
}
