import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

enum OAuthProvider {
    static func settings(_ kind: SourceKind) -> (authorize: String, token: String, scope: String) {
        switch kind {
        case .googleDrive: return ("https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token", "https://www.googleapis.com/auth/drive.readonly")
        case .oneDrive: return ("https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "https://login.microsoftonline.com/common/oauth2/v2.0/token", "offline_access Files.Read")
        case .aliyun: return ("https://openapi.alipan.com/oauth/authorize", "https://openapi.alipan.com/oauth/access_token", "user:base,file:all:read")
        default: return ("https://www.dropbox.com/oauth2/authorize", "https://api.dropboxapi.com/oauth2/token", "")
        }
    }
    static func exchange(kind: SourceKind, parameters: [String: String], previous: SourceSecret) async throws -> SourceSecret {
        var request = URLRequest(url: URL(string: settings(kind).token)!); request.httpMethod = "POST"
        if kind == .aliyun {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var encoded = URLComponents(); encoded.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let value = try await HTTPClient.json(request)
        guard let token = value["access_token"] as? String else { throw AppError.invalidResponse }
        var result = previous; result.token = token; result.refreshToken = value["refresh_token"] as? String ?? previous.refreshToken
        result.expiresAt = (value["expires_in"] as? Double).map { Date().addingTimeInterval($0) }; return result
    }
}

@MainActor
final class CloudOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    func signIn(kind: SourceKind, clientID: String, clientSecret: String, redirect: String) async throws -> SourceSecret {
        guard !clientID.isEmpty, let scheme = URL(string: redirect)?.scheme else { throw AppError.message("请填写自己的 OAuth Client ID 和回调地址。") }
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString; let provider = OAuthProvider.settings(kind)
        var parts = URLComponents(string: provider.authorize)!
        var query = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "state": state, "code_challenge": challenge, "code_challenge_method": "S256"]
        if !provider.scope.isEmpty { query["scope"] = provider.scope }
        if kind == .googleDrive { query["access_type"] = "offline"; query["prompt"] = "consent" }
        if kind == .dropbox { query["token_access_type"] = "offline" }
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: parts.url!, callbackURLScheme: scheme) { url, error in
                if let error { continuation.resume(throwing: error) } else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: AppError.invalidResponse) }
            }
            session.presentationContextProvider = self; self.session = session
            if !session.start() { continuation.resume(throwing: AppError.message("无法打开授权窗口。")) }
        }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.first(where: { $0.name == "state" })?.value == state,
              let code = values.first(where: { $0.name == "code" })?.value else { throw AppError.message("授权回调无效或已取消。") }
        var parameters = ["grant_type": "authorization_code", "code": code, "client_id": clientID, "redirect_uri": redirect, "code_verifier": verifier]
        if !clientSecret.isEmpty { parameters["client_secret"] = clientSecret }
        return try await OAuthProvider.exchange(kind: kind, parameters: parameters, previous: SourceSecret(clientID: clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret))
    }
}

actor CloudTokenBroker {
    static let shared = CloudTokenBroker()
    private var refreshes: [UUID: Task<SourceSecret, Error>] = [:]
    func resolve(_ source: MediaSource, fallback: SourceSecret) async throws -> SourceSecret {
        let secret = try KeychainVault.read(SourceSecret.self, account: source.id.uuidString) ?? fallback
        guard let expiry = secret.expiresAt, expiry.timeIntervalSinceNow < 120, let refresh = secret.refreshToken, let client = secret.clientID else { return secret }
        if let task = refreshes[source.id] { return try await task.value }
        let task = Task {
            var parameters = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client]
            if let key = secret.clientSecret { parameters["client_secret"] = key }
            let next = try await OAuthProvider.exchange(kind: source.kind, parameters: parameters, previous: secret)
            guard let current = try KeychainVault.read(SourceSecret.self, account: source.id.uuidString), current.refreshToken == refresh else { throw CancellationError() }
            try KeychainVault.save(next, account: source.id.uuidString); return next
        }
        refreshes[source.id] = task; defer { refreshes[source.id] = nil }; return try await task.value
    }
}
