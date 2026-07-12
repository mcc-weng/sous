import AuthenticationServices
import CryptoKit
import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rawNonce = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Sous").font(.largeTitle.bold())
            SignInWithAppleButton(.signIn) { request in
                rawNonce = Self.randomNonce()
                request.requestedScopes = [.email]
                request.nonce = Self.sha256(rawNonce)
            } onCompletion: { result in
                Task { await handle(result) }
            }
            .frame(height: 50)
            .padding(.horizontal, 40)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
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
