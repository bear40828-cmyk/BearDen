import SwiftUI
import SafariServices
import Network
import CryptoKit
import Security

struct ChatGPTCredential: Codable, Sendable {
    var email: String?
    var issuer: String
    var subject: String
    var clientID: String
    var hostID: String
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresAt: Date
    var scopes: [String]

    var canUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}

enum ChatGPTAuthError: LocalizedError {
    case cancelled
    case invalidCallback
    case invalidState
    case missingClientID
    case missingToken(String)
    case invalidIDToken(String)
    case permissionMissing
    case missingCredential
    case server(String)
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .cancelled: return "登录已取消。"
        case .invalidCallback: return "没有收到有效的 ChatGPT 登录回调。"
        case .invalidState: return "登录校验失败，请重新登录。"
        case .missingClientID: return "OpenAI 没有返回已注册的客户端 ID。"
        case .missingToken(let name): return "登录结果缺少 \(name)。"
        case .invalidIDToken(let reason): return "ChatGPT 身份校验失败：\(reason)"
        case .permissionMissing: return "登录成功，但没有授权使用 ChatGPT 套餐。请重新登录并允许套餐用量。"
        case .missingCredential: return "ChatGPT 登录信息已失效，请重新登录。"
        case .server(let message): return message
        case .incompleteResponse: return "回复在完成前中断了，请重试。"
        }
    }
}

enum ChatGPTCredentialStore {
    // Keychain service follows the bundle identifier so differently-identified builds keep separate stores.
    private static let service = (Bundle.main.bundleIdentifier ?? "app.bearden.mailbox") + ".ai"

    static func save(_ credential: ChatGPTCredential, account: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(account: String?) -> ChatGPTCredential? {
        guard let account, !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredential.self, from: data)
    }

    static func copy(from source: String, to destination: String) throws {
        guard let credential = load(account: source) else { throw ChatGPTAuthError.missingCredential }
        try save(credential, account: destination)
    }
}

@MainActor
final class ChatGPTOAuthController: ObservableObject {
    @Published var authorizationURL: URL?
    @Published var isAuthenticating = false
    @Published var connectedEmail: String?

    private let callbackQueue = DispatchQueue(label: "app.bearden.chatgpt.oauth")
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?

    func signIn(storageAccount: String) async throws -> ChatGPTCredential {
        guard !isAuthenticating else { throw ChatGPTAuthError.server("登录正在进行中。") }
        isAuthenticating = true
        defer {
            isAuthenticating = false
            listener?.cancel()
            listener = nil
            authorizationURL = nil
        }

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 32)
        let nonce = Self.randomURLSafeString(byteCount: 32)
        let port = try await startListener()
        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"

        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "dynamic_agent_client"),
            URLQueryItem(name: "agent_name_hint", value: "熊窝"),
            URLQueryItem(name: "ext_agent_host_id", value: Self.hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        guard let url = components.url else { throw ChatGPTAuthError.invalidCallback }

        let callback = try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            authorizationURL = url
        }
        guard callback["state"] == state else { throw ChatGPTAuthError.invalidState }
        if let oauthError = callback["error"] {
            throw ChatGPTAuthError.server(callback["error_description"] ?? oauthError)
        }
        guard let code = callback["code"], !code.isEmpty else { throw ChatGPTAuthError.invalidCallback }
        guard let clientID = callback["client_id"], !clientID.isEmpty,
              clientID != "dynamic_agent_client" else { throw ChatGPTAuthError.missingClientID }

        let tokenJSON = try await Self.tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": "https://api.openai.com/v1"
        ])
        guard let idToken = tokenJSON["id_token"] as? String else { throw ChatGPTAuthError.missingToken("ID token") }
        guard let accessToken = tokenJSON["access_token"] as? String else { throw ChatGPTAuthError.missingToken("access token") }
        guard let refreshToken = tokenJSON["refresh_token"] as? String else { throw ChatGPTAuthError.missingToken("refresh token") }
        let identity = try await ChatGPTJWT.verify(idToken, clientID: clientID, nonce: nonce)
        let scopeValue: Any = tokenJSON["scope"] ?? callback["scope"] ?? ""
        let scopes = Self.scopes(from: scopeValue)
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.permissionMissing }
        let expiresIn = (tokenJSON["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let credential = ChatGPTCredential(
            email: identity.email,
            issuer: identity.issuer,
            subject: identity.subject,
            clientID: clientID,
            hostID: Self.hostID,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenJSON["token_type"] as? String ?? "Bearer",
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scopes
        )
        try ChatGPTCredentialStore.save(credential, account: storageAccount)
        connectedEmail = identity.email
        return credential
    }

    func cancel() {
        guard let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        authorizationURL = nil
        listener?.cancel()
        continuation.resume(throwing: ChatGPTAuthError.cancelled)
    }

    private func startListener() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            listener.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    guard let value = listener.port?.rawValue else {
                        finished = true
                        continuation.resume(throwing: ChatGPTAuthError.invalidCallback)
                        return
                    }
                    finished = true
                    continuation.resume(returning: value)
                case .failed(let error):
                    finished = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    finished = true
                    continuation.resume(throwing: ChatGPTAuthError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: callbackQueue)
        }
        return port
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: callbackQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""
            var values: [String: String] = [:]
            if let components = URLComponents(string: "http://127.0.0.1\(target)"),
               components.path == "/auth/callback" {
                for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
            }
            let success = !values.isEmpty
            let title = success ? "登录完成" : "登录失败"
            let body = success ? "可以关闭此页面并返回熊窝。" : "没有收到有效回调，请返回熊窝重试。"
            let html = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(title)</title><style>body{font-family:-apple-system;padding:48px;text-align:center;background:#fff4f8;color:#222}h1{color:#e76d9d}</style><h1>\(title)</h1><p>\(body)</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            Task { @MainActor in
                guard let continuation = self.callbackContinuation else { return }
                self.callbackContinuation = nil
                self.authorizationURL = nil
                if success { continuation.resume(returning: values) }
                else { continuation.resume(throwing: ChatGPTAuthError.invalidCallback) }
            }
        }
    }

    fileprivate static var hostID: String {
        let key = "chatgpt.ext_agent_host_id"
        if let saved = UserDefaults.standard.string(forKey: key), saved.hasPrefix("urn:uuid:") { return saved }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    nonisolated fileprivate static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.server("登录服务器没有响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = json?["error_description"] as? String ?? json?["error"] as? String ?? "登录失败（HTTP \(http.statusCode)）"
            throw ChatGPTAuthError.server(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError.server("无法读取登录结果。")
        }
        return json
    }

    nonisolated fileprivate static func scopes(from value: Any) -> [String] {
        if let string = value as? String { return string.split(separator: " ").map(String.init) }
        if let array = value as? [String] { return array }
        return []
    }

    fileprivate static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        return base64URL(Data(bytes))
    }

    fileprivate static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ChatGPTAuthorizationSheet: View {
    @ObservedObject var controller: ChatGPTOAuthController

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(
                get: { controller.authorizationURL != nil },
                set: { if !$0, controller.authorizationURL != nil { controller.cancel() } }
            )) {
                if let url = controller.authorizationURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
            }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum ChatGPTJWT {
    struct Identity {
        let issuer: String
        let subject: String
        let email: String?
    }

    static func verify(_ token: String, clientID: String, nonce: String) async throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decodeBase64URL(String(parts[0])),
              let payloadData = decodeBase64URL(String(parts[1])),
              let signature = decodeBase64URL(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError.invalidIDToken("格式不正确")
        }
        guard header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw ChatGPTAuthError.invalidIDToken("签名算法不受支持")
        }
        let key = try await publicKey(kid: kid)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        var verificationError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signature as CFData, &verificationError) else {
            throw ChatGPTAuthError.invalidIDToken("签名无效")
        }
        guard let issuer = claims["iss"] as? String, issuer == "https://auth.openai.com" else {
            throw ChatGPTAuthError.invalidIDToken("签发方不正确")
        }
        let audienceOK: Bool
        if let audience = claims["aud"] as? String { audienceOK = audience == clientID }
        else if let audiences = claims["aud"] as? [String] { audienceOK = audiences.contains(clientID) }
        else { audienceOK = false }
        guard audienceOK else { throw ChatGPTAuthError.invalidIDToken("接收方不正确") }
        guard let expiration = (claims["exp"] as? NSNumber)?.doubleValue,
              expiration > Date().timeIntervalSince1970 else {
            throw ChatGPTAuthError.invalidIDToken("令牌已过期")
        }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.invalidIDToken("nonce 不匹配") }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTAuthError.invalidIDToken("缺少账户标识")
        }
        return Identity(issuer: issuer, subject: subject, email: claims["email"] as? String)
    }

    private static func publicKey(kid: String) async throws -> SecKey {
        let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let (discoveryData, discoveryResponse) = try await URLSession.shared.data(from: discoveryURL)
        guard (discoveryResponse as? HTTPURLResponse)?.statusCode == 200,
              let discovery = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any],
              let jwksString = discovery["jwks_uri"] as? String,
              let jwksURL = URL(string: jwksString) else {
            throw ChatGPTAuthError.invalidIDToken("无法读取 OpenAI OIDC 配置")
        }
        let (jwksData, jwksResponse) = try await URLSession.shared.data(from: jwksURL)
        guard (jwksResponse as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid }),
              jwk["kty"] as? String == "RSA",
              let nString = jwk["n"] as? String,
              let eString = jwk["e"] as? String,
              let modulus = decodeBase64URL(nString),
              let exponent = decodeBase64URL(eString) else {
            throw ChatGPTAuthError.invalidIDToken("找不到 OpenAI 公钥")
        }
        let der = rsaPublicKeyDER(modulus: modulus, exponent: exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw ChatGPTAuthError.invalidIDToken("OpenAI 公钥无法使用")
        }
        return key
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func length(_ count: Int) -> [UInt8] {
            if count < 128 { return [UInt8(count)] }
            var value = count
            var bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data.drop(while: { $0 == 0 }))
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30] + length(body.count) + body)
    }
}

actor ChatGPTCredentialManager {
    static let shared = ChatGPTCredentialManager()

    func validCredential(account: String?) async throws -> ChatGPTCredential {
        guard let account, var credential = ChatGPTCredentialStore.load(account: account) else {
            throw ChatGPTAuthError.missingCredential
        }
        if credential.expiresAt > Date().addingTimeInterval(90) { return credential }
        let json = try await ChatGPTOAuthController.tokenRequest([
            "grant_type": "refresh_token",
            "client_id": credential.clientID,
            "refresh_token": credential.refreshToken,
            "resource": "https://api.openai.com/v1"
        ])
        guard let accessToken = json["access_token"] as? String else { throw ChatGPTAuthError.missingToken("access token") }
        credential.accessToken = accessToken
        credential.refreshToken = json["refresh_token"] as? String ?? credential.refreshToken
        credential.idToken = json["id_token"] as? String ?? credential.idToken
        credential.tokenType = json["token_type"] as? String ?? credential.tokenType
        let refreshedScopes = ChatGPTOAuthController.scopes(from: json["scope"] as Any)
        if !refreshedScopes.isEmpty { credential.scopes = refreshedScopes }
        guard credential.canUsePlan else { throw ChatGPTAuthError.permissionMissing }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        credential.expiresAt = Date().addingTimeInterval(expiresIn)
        try ChatGPTCredentialStore.save(credential, account: account)
        return credential
    }
}

enum ChatGPTPlanClient {
    static func listModels(account: String?) async throws -> [String] {
        let credential = try await ChatGPTCredentialManager.shared.validCredential(account: account)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.server("模型列表没有响应。") }
        guard (200..<300).contains(http.statusCode) else { throw serverError(data: data, status: http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["models"] as? [[String: Any]] else {
            throw ChatGPTAuthError.server("无法读取 ChatGPT 模型列表。")
        }
        let visible = records.compactMap { record -> String? in
            guard record["visibility"] as? String == "list" else { return nil }
            return record["slug"] as? String
        }
        var seen = Set<String>()
        return visible.filter { seen.insert($0).inserted }
    }

    static func send(
        account: String?,
        messages: [(role: String, text: String)],
        model: String,
        nickname: String,
        conversation: AIConversation? = nil,
        richMessages: [LocalAIMessage]? = nil,
        onActivity: ChatActivityHandler? = nil
    ) async throws -> String {
        let credential = try await ChatGPTCredentialManager.shared.validCredential(account: account)
        if let conversation, let richMessages {
            return try await AIModelTools.sendResponses(messages: richMessages, conversation: conversation, accessToken: credential.accessToken, onActivity: onActivity)
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let input = messages.map { ["role": $0.role, "content": $0.text] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": "你在熊窝里的昵称是\(nickname)。自然地和用户对话。\n\n\(MessageBubbleSplitter.promptInstruction)",
            "input": input,
            "store": false,
            "stream": true
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.server("ChatGPT 没有响应。") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw serverError(data: data, status: http.statusCode)
        }
        var output = ""
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                output += event["delta"] as? String ?? ""
            case "response.completed":
                completed = true
            case "response.failed", "response.incomplete":
                let responseObject = event["response"] as? [String: Any]
                let error = responseObject?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? error?["code"] as? String ?? "ChatGPT 没有完成回复。"
                throw ChatGPTAuthError.server(message)
            default:
                break
            }
        }
        guard completed else { throw ChatGPTAuthError.incompleteResponse }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func serverError(data: Data, status: Int) -> ChatGPTAuthError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String
            let message = error["message"] as? String
            if code == "subscription_sharing_usage_limit_exceeded" { return .server("ChatGPT 套餐额度暂时用完了。") }
            if code == "subscription_sharing_usage_unavailable" { return .server("当前 ChatGPT 套餐暂时不能用于这个请求。") }
            if let message { return .server(message) }
        }
        let detail = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
        return .server(detail.isEmpty ? "请求失败（HTTP \(status)）" : String(detail))
    }
}
