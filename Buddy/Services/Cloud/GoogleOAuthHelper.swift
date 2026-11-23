import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

public enum GoogleOAuthError: LocalizedError, Equatable, Sendable {
    case invalidClientID
    case cancelled
    case stateMismatch
    case missingAuthorizationCode
    case providerError(String)
    case sessionStartFailed

    public var errorDescription: String? {
        switch self {
        case .invalidClientID:
            return "Google iOS Client ID is invalid. Expected a value ending in .apps.googleusercontent.com."
        case .cancelled:
            return "Google sign-in was cancelled."
        case .stateMismatch:
            return "Google sign-in security verification failed. Please try again."
        case .missingAuthorizationCode:
            return "Google did not return an authorization code. Please try again."
        case .providerError(let detail):
            return "Google sign-in error: \(detail)"
        case .sessionStartFailed:
            return "Could not open the Google sign-in browser sheet."
        }
    }
}

/// Zero-SDK OAuth 2.0 + PKCE (RFC 7636 / RFC 8252) helper for Google Sign-In on iOS.
/// Works seamlessly on SideStore free Apple IDs with zero third-party SDKs and zero extra App IDs.
public enum GoogleOAuthHelper {
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let googleClientSuffix = ".apps.googleusercontent.com"

    /// Converts a Google iOS OAuth Client ID (e.g. `12345-abc.apps.googleusercontent.com`)
    /// into its reversed-DNS custom URL scheme (`com.googleusercontent.apps.12345-abc`).
    public static func reversedClientID(from clientID: String) -> String? {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(googleClientSuffix) else {
            return nil
        }
        let prefixEnd = trimmed.index(trimmed.endIndex, offsetBy: -googleClientSuffix.count)
        let prefix = String(trimmed[..<prefixEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty,
              !prefix.contains("."),
              !prefix.contains("/"),
              !prefix.contains(":"),
              !prefix.contains(" ") else {
            return nil
        }
        return "com.googleusercontent.apps.\(prefix)"
    }

    /// Returns Google's RFC 8252 single-slash iOS redirect URI (`com.googleusercontent.apps.<id>:/oauth2redirect`).
    public static func redirectURI(for clientID: String) -> String? {
        guard let reversed = reversedClientID(from: clientID) else { return nil }
        return "\(reversed):/oauth2redirect"
    }

    /// Generates a cryptographically random PKCE `(verifier, challenge)` pair using S256.
    public static func generatePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomURLSafeString(byteCount: 32)
        return (verifier, codeChallenge(for: verifier))
    }

    /// Computes RFC 7636 S256 `code_challenge = BASE64URL(SHA256(ASCII(verifier)))` without padding.
    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// Generates a random CSRF `state` token verified on the OAuth redirect callback.
    public static func generateState() -> String {
        randomURLSafeString(byteCount: 16)
    }

    /// Builds the Google OAuth 2.0 authorization URL with PKCE and `openid email profile` scopes.
    public static func buildAuthorizationURL(
        clientID: String,
        codeChallenge: String,
        state: String
    ) -> URL? {
        let cleanClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let redirectURI = redirectURI(for: cleanClientID),
              var components = URLComponents(string: authorizationEndpoint) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: cleanClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        return components.url
    }

    /// Extracts and validates the OAuth authorization `code` from the redirect callback URL.
    public static func extractAuthorizationCode(
        from callbackURL: URL,
        expectedState: String
    ) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        let items = components.queryItems ?? []
        func value(for name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        if let errorCode = value(for: "error"), !errorCode.isEmpty {
            if errorCode == "access_denied" {
                throw GoogleOAuthError.cancelled
            }
            let detail = value(for: "error_description") ?? errorCode
            throw GoogleOAuthError.providerError(detail)
        }

        guard let returnedState = value(for: "state"), returnedState == expectedState else {
            throw GoogleOAuthError.stateMismatch
        }

        guard let code = value(for: "code"), !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }

        return code
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return base64URLEncode(Data(bytes))
    }
}

/// Presents `ASWebAuthenticationSession` on the active foreground iOS window scene and returns
/// the OAuth redirect callback URL cleanly via Swift concurrency.
@MainActor
public final class GoogleWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        // Cancel any lingering in-flight session defensively.
        if let existing = activeSession {
            existing.cancel()
            activeSession = nil
        }
        if let prior = pendingContinuation {
            pendingContinuation = nil
            prior.resume(throwing: GoogleOAuthError.cancelled)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            self.finish(with: .failure(GoogleOAuthError.cancelled))
                        } else {
                            self.finish(with: .failure(GoogleOAuthError.providerError(error.localizedDescription)))
                        }
                        return
                    }
                    guard let callbackURL else {
                        self.finish(with: .failure(GoogleOAuthError.missingAuthorizationCode))
                        return
                    }
                    self.finish(with: .success(callbackURL))
                }
            }

            session.presentationContextProvider = self
            // Share Safari's Google sign-in session so friends get 1-tap login.
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session

            if !session.start() {
                self.finish(with: .failure(GoogleOAuthError.sessionStartFailed))
            }
        }
    }

    private func finish(with result: Result<URL, Error>) {
        activeSession = nil
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        switch result {
        case .success(let callbackURL):
            continuation.resume(returning: callbackURL)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeKeyWindow = scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow) {
            return activeKeyWindow
        }
        if let anyWindow = scenes.flatMap(\.windows).first {
            return anyWindow
        }
        return ASPresentationAnchor()
    }
}
