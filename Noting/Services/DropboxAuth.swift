import CryptoKit
import Foundation
import Security

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
@MainActor
final class DropboxAuth {
    static let appKey = "sisv9mjbb6xqw4e"

    private static let authURL = "https://www.dropbox.com/oauth2/authorize"
    private static let tokenURL = "https://api.dropboxapi.com/oauth2/token"
    private static let callbackScheme = "noting"
    private static let redirectURI = "\(callbackScheme)://oauth/callback"

    private static let refreshTokenKey = "com.artem.noting.dropbox.refresh_token"
    private static let accessTokenKey = "com.artem.noting.dropbox.access_token"
    private static let expiresAtKey = "dropbox_token_expires_at"

    private(set) var isConnected: Bool

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?
    private var codeVerifier: String?
    private var authContinuation: CheckedContinuation<URL, Error>?

    init() {
        let refresh = Self.keychainRead(key: Self.refreshTokenKey)
        self.isConnected = refresh != nil
        self.refreshToken = refresh
        self.accessToken = Self.keychainRead(key: Self.accessTokenKey)
        if let ms = UserDefaults.standard.object(forKey: Self.expiresAtKey) as? Double {
            self.expiresAt = Date(timeIntervalSince1970: ms)
        }
    }

    // MARK: - OAuth PKCE Flow

    func authorize() async throws {
        let verifier = Self.generateCodeVerifier()
        self.codeVerifier = verifier
        let codeChallenge = Self.generateCodeChallenge(verifier)

        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]

        let url = components.url!

        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif

        // Start a timeout task that will cancel auth after 5 minutes
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(300))
            if let continuation = self.authContinuation {
                self.authContinuation = nil
                self.codeVerifier = nil
                continuation.resume(throwing: DropboxAuthError.authError("Timeout"))
            }
        }

        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.authContinuation = continuation
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            authContinuation = nil
            codeVerifier = nil
            throw error
        }

        let components2 = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        if let error = components2?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw DropboxAuthError.authError(error)
        }
        guard let code = components2?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw DropboxAuthError.noCode
        }

        let data = try await Self.tokenRequest([
            "code": code,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
            "client_id": Self.appKey,
            "redirect_uri": Self.redirectURI,
        ])
        try persistTokens(data)
    }

    func handleCallback(url: URL) {
        guard let continuation = authContinuation else { return }
        authContinuation = nil
        codeVerifier = nil
        continuation.resume(returning: url)
    }

    // MARK: - Token Management

    func getValidAccessToken() async throws -> String {
        guard isConnected else {
            throw DropboxAuthError.notConnected
        }

        if let token = accessToken, let expires = expiresAt, Date.now < expires {
            return token
        }

        return try await refreshAccessToken()
    }

    func clearTokens() {
        Self.keychainDelete(key: Self.refreshTokenKey)
        Self.keychainDelete(key: Self.accessTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.expiresAtKey)
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        isConnected = false
    }

    // MARK: - Private

    @discardableResult
    private func refreshAccessToken() async throws -> String {
        guard let refresh = refreshToken else {
            throw DropboxAuthError.notConnected
        }

        let data = try await Self.tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.appKey,
        ])
        guard let token = data["access_token"] as? String,
              let expiresIn = data["expires_in"] as? Int else {
            throw DropboxAuthError.authError("Invalid token response")
        }
        let expires = Date.now.addingTimeInterval(TimeInterval(expiresIn - 300))

        accessToken = token
        expiresAt = expires
        Self.keychainWrite(key: Self.accessTokenKey, value: token)
        UserDefaults.standard.set(expires.timeIntervalSince1970, forKey: Self.expiresAtKey)

        return token
    }

    private static func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: tokenURL) else {
            throw DropboxAuthError.authError("Invalid token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxAuthError.authError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw DropboxAuthError.tokenExchangeFailed(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DropboxAuthError.authError("Invalid JSON response")
        }
        return json
    }

    private func persistTokens(_ data: [String: Any]) throws {
        guard let access = data["access_token"] as? String,
              let expiresIn = data["expires_in"] as? Int else {
            throw DropboxAuthError.authError("Invalid token response")
        }
        let refresh = data["refresh_token"] as? String ?? refreshToken ?? ""
        let expires = Date.now.addingTimeInterval(TimeInterval(expiresIn - 300))

        accessToken = access
        refreshToken = refresh
        expiresAt = expires
        isConnected = true

        Self.keychainWrite(key: Self.accessTokenKey, value: access)
        Self.keychainWrite(key: Self.refreshTokenKey, value: refresh)
        UserDefaults.standard.set(expires.timeIntervalSince1970, forKey: Self.expiresAtKey)
    }

    // MARK: - Keychain

    private static func keychainWrite(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func keychainRead(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<64).map { _ in chars.randomElement()! })
    }

    private static func generateCodeChallenge(_ verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum DropboxAuthError: LocalizedError {
    case noCallback
    case noCode
    case notConnected
    case authError(String)
    case tokenExchangeFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noCallback: "No callback received"
        case .noCode: "No authorization code"
        case .notConnected: "Not connected to Dropbox"
        case .authError(let msg): "Dropbox error: \(msg)"
        case .tokenExchangeFailed(let code): "Token exchange failed (\(code))"
        }
    }
}
