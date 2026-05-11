import SwiftUI
import WebKit

struct AuthView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @State private var showWebView = false
    @State private var glowPulse = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            // Animated radial glow
            RadialGradient(
                colors: [
                    Color.ytRed.opacity(glowPulse ? 0.22 : 0.10),
                    Color.appBg
                ],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 480
            )
            .ignoresSafeArea()
            .animation(
                .easeInOut(duration: 3.5).repeatForever(autoreverses: true),
                value: glowPulse
            )

            VStack(spacing: 0) {
                Spacer()

                // Wordmark
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.ytRed.opacity(0.12))
                            .frame(width: 96, height: 96)
                        Circle()
                            .fill(Color.ytRed.opacity(0.08))
                            .frame(width: 72, height: 72)
                        Image(systemName: "waveform")
                            .font(.system(size: 36, weight: .ultraLight))
                            .foregroundStyle(Color.ytRed)
                    }
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                    VStack(spacing: 8) {
                        Text("YTWATCH")
                            .font(.system(size: 34, weight: .black))
                            .tracking(10)
                            .foregroundStyle(.white)

                        Text("YouTube Music  ·  Apple Watch")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(2.5)
                            .foregroundStyle(Color.appFaint)
                    }
                    .offset(y: appeared ? 0 : 12)
                    .opacity(appeared ? 1 : 0)
                }

                Spacer()

                // CTA
                VStack(spacing: 16) {
                    Button(action: { showWebView = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 17))
                            Text("Continue with Google")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Your credentials are stored securely in Keychain and never leave your device.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appGhost)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 52)
                .offset(y: appeared ? 0 : 24)
                .opacity(appeared ? 1 : 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            glowPulse = true
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) {
                appeared = true
            }
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
        .preferredColorScheme(.dark)
    }
}

struct WebLoginView: UIViewRepresentable {
    var onLoginComplete: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onLoginComplete) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: ([HTTPCookie]) -> Void
        private var didComplete = false

        init(onComplete: @escaping ([HTTPCookie]) -> Void) { self.onComplete = onComplete }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didComplete,
                  let urlString = webView.url?.absoluteString,
                  urlString.hasPrefix("https://music.youtube.com"),
                  !urlString.contains("/ServiceLogin"),
                  !urlString.contains("/signin") else { return }

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
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
        }
    }
}
