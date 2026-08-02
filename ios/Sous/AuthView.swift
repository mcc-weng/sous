import AuthenticationServices
import CryptoKit
import SwiftUI

/// A1 · 扉頁 (Auth) — title page, not a marketing screen: seal, tracked subtitle,
/// headline, rule, promise, then a footer with the outlined sign-in action.
/// Reference: design_handoff_sous_m3/README.md "A1 · 扉頁 (Auth)" and
/// Sous App v2.dc.html lines 45-61.
struct AuthView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rawNonce = ""
    @State private var errorText: String?

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    /// `book_title` copy_pack key (already seeded in Task 2) — reused here for the
    /// tracked kicker label above the headline; also used on the Settings colophon.
    private var kicker: String { model.personaCopy["book_title"] ?? "私廚手記" }

    /// `app_subtitle` copy_pack key. The mock hard-breaks this into two centred lines
    /// at the comma; normalize both the ASCII and full-width comma to a hard newline
    /// so the split doesn't silently collapse to one line if the copy value changes.
    private var headline: String {
        let raw = model.personaCopy["app_subtitle"] ?? "你的私廚,在口袋裡"
        return raw.replacingOccurrences(of: "，", with: "\n")
            .replacingOccurrences(of: ",", with: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                sealSquare
                Text(kicker)
                    .font(.custom(sansName, size: 10))
                    .tracking(6.2) // .62em at 10pt
                    .foregroundStyle(PaperTokens.seal)
                    .padding(.top, 30)
                Text(headline)
                    .font(.custom(serifName, size: 38))
                    .tracking(1.9) // .05em at 38pt
                    .lineSpacing(19) // lh 1.5
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PaperTokens.ink)
                    .padding(.top, 22)
                Rectangle()
                    .fill(PaperTokens.leader) // ink @ 30%
                    .frame(width: 24, height: 1)
                    .padding(.vertical, Spacing.lg)
                Text("小當家會記住你家的口味、\n排好這一週,\n然後在爐邊陪你把它煮出來。")
                    .font(.custom(serifName, size: 14))
                    .lineSpacing(16.8) // lh 2.2
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                SignInWithAppleButton(.signIn) { request in
                    rawNonce = Self.randomNonce()
                    request.requestedScopes = [.email]
                    request.nonce = Self.sha256(rawNonce)
                } onCompletion: { result in
                    Task { await handle(result) }
                }
                .signInWithAppleButtonStyle(.whiteOutline)
                .frame(height: 50)

                if let errorText {
                    Text(errorText)
                        .font(.custom(sansName, size: 12))
                        .foregroundStyle(.red)
                        .padding(.top, Spacing.sm)
                }

                Text("我們只存你家的口味與菜單")
                    .font(.custom(sansName, size: 10.5))
                    .tracking(1.68) // .16em at 10.5pt
                    .lineSpacing(10.5) // lh 2
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PaperTokens.inkFaint)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 52)
        .padding(.bottom, Spacing.pageMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperTokens.stock)
    }

    private var sealSquare: some View {
        Text("當")
            .font(.custom(serifName, size: 18))
            .foregroundStyle(PaperTokens.slip)
            .frame(width: 40, height: 40)
            .background(PaperTokens.seal)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        do {
            guard case .success(let auth) = result,
                  let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else { throw URLError(.userAuthenticationRequired) }
            try await model.signInWithApple(idToken: idToken, nonce: rawNonce)
        } catch {
            errorText = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
