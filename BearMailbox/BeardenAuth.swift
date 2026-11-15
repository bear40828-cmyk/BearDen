import Foundation
import WebKit

/// Built-in device credential for the configured moments server and the group reply API.
/// The value is not stored in source control: it is read from DeviceToken.txt,
/// which is placed into the app bundle at packaging time.
/// The server host comes from Settings -> Server address; with no address
/// configured there is no host to authenticate against and auth is inert.
enum BeardenAuth {
    static var momentsHost: String? { ServerConfig.momentsBase?.host }

    static let token: String = {
        guard let url = Bundle.main.url(forResource: "DeviceToken", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static var bearer: String? { token.isEmpty ? nil : "Bearer \(token)" }

    static var cookie: HTTPCookie? {
        guard let host = momentsHost, !token.isEmpty else { return nil }
        return HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "bd",
            .value: token,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(10 * 365 * 24 * 3600),
        ])
    }

    /// Cookie for URLSession.shared (native feed, albums, favorites, image loading).
    static func seedNativeCookie() {
        if let cookie { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    /// Adds the Authorization header when the request targets the moments host.
    static func authorize(_ request: inout URLRequest) {
        guard let host = momentsHost, request.url?.host == host, let bearer = bearer else { return }
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }

    /// Seeds the WKWebView cookie store before the first load so page fetch/XHR carry it.
    static func seed(_ store: WKHTTPCookieStore, then done: @escaping () -> Void) {
        guard let cookie else { done(); return }
        store.setCookie(cookie) { done() }
    }
}
