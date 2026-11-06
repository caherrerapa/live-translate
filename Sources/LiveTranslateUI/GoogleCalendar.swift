import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Google Calendar, read-only: when a session starts, the event happening now gives it a title,
/// its attendees and its agenda. Sign-in is Google's OAuth for installed apps (PKCE, no client
/// secret) in the system's secure browser sheet. The refresh token lives in the Keychain.
/// The OAuth client ID comes from the user's own Google Cloud project (iOS client type).
@MainActor
final class GoogleCalendar: NSObject, ObservableObject {
    static let shared = GoogleCalendar()

    @Published private(set) var account: String?
    @Published private(set) var working = false
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: Self.clientKey) }
    }

    private static let clientKey = "googleClientID"
    private static let accountKey = "googleAccount"
    private static let keychainService = "com.caherrerapa.LiveTranslate.google"
    private static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?

    enum Failure: LocalizedError {
        case noClientID, cancelled, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noClientID: return "Paste your Google OAuth client ID first."
            case .cancelled: return "Sign-in was cancelled."
            case .badResponse(let text): return "Google answered: \(text)"
            }
        }
    }

    override init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientKey) ?? ""
        super.init()
        if Self.readRefreshToken() != nil {
            account = UserDefaults.standard.string(forKey: Self.accountKey) ?? "Google Calendar"
        }
    }

    var isConnected: Bool { account != nil }

    /// "123-abc.apps.googleusercontent.com" signs in through "com.googleusercontent.apps.123-abc".
    private var redirectScheme: String? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        let prefix = id.dropLast(".apps.googleusercontent.com".count)
        return "com.googleusercontent.apps.\(prefix)"
    }

    // MARK: Sign in

    func signIn() async throws {
        guard let scheme = redirectScheme else { throw Failure.noClientID }
        working = true
        defer { working = false }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = "\(scheme):/oauth2redirect"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID.trimmingCharacters(in: .whitespaces)),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: error ?? Failure.cancelled)
                }
            }
            session.presentationContextProvider = self
            authSession = session
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw Failure.badResponse("no authorization code")
        }
        let tokens = try await tokenRequest([
            "client_id": clientID.trimmingCharacters(in: .whitespaces),
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ])
        guard let refresh = tokens["refresh_token"] as? String else { throw Failure.badResponse("no refresh token") }
        Self.saveRefreshToken(refresh)
        store(tokens)
        // The primary calendar's id is the account's address.
        let primary = try? await get("calendars/primary", query: [])
        let name = primary?["id"] as? String ?? "Google Calendar"
        UserDefaults.standard.set(name, forKey: Self.accountKey)
        account = name
    }

    func signOut() {
        if let refresh = Self.readRefreshToken() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(refresh)")!)
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }
        Self.deleteRefreshToken()
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        accessToken = nil
        account = nil
    }

    // MARK: Events

    /// The timed event happening now (or starting within ten minutes) that the user hasn't declined.
    func currentMeeting(at now: Date = Date()) async -> MeetingContext? {
        guard isConnected else { return nil }
        let format = ISO8601DateFormatter()
        guard let object = try? await get("calendars/primary/events", query: [
            .init(name: "timeMin", value: format.string(from: now.addingTimeInterval(-3 * 3600))),
            .init(name: "timeMax", value: format.string(from: now.addingTimeInterval(10 * 60))),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "20"),
        ]), let items = object["items"] as? [[String: Any]] else { return nil }
        let events = items.compactMap(Self.meeting(from:))
        return events
            .filter { $0.start <= now.addingTimeInterval(10 * 60) && $0.end >= now }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    nonisolated static func meeting(from item: [String: Any]) -> MeetingContext? {
        // All-day events carry "date", not "dateTime": they are not meetings.
        guard let start = (item["start"] as? [String: Any])?["dateTime"] as? String,
              let end = (item["end"] as? [String: Any])?["dateTime"] as? String,
              let startDate = parseDate(start), let endDate = parseDate(end) else { return nil }
        let attendees = item["attendees"] as? [[String: Any]] ?? []
        if attendees.contains(where: { ($0["self"] as? Bool) == true && ($0["responseStatus"] as? String) == "declined" }) {
            return nil
        }
        let names = attendees
            .filter { ($0["resource"] as? Bool) != true }
            .compactMap { ($0["displayName"] as? String) ?? ($0["email"] as? String) }
        return MeetingContext(
            title: item["summary"] as? String ?? "Meeting",
            start: startDate,
            end: endDate,
            attendees: names,
            agenda: plainText(item["description"] as? String ?? ""),
            link: item["htmlLink"] as? String ?? ""
        )
    }

    nonisolated private static func parseDate(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text)
    }

    /// Event descriptions are often HTML.
    nonisolated private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP

    private func get(_ path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        let token = try await validToken()
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(((object["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)")
        }
        return object
    }

    private func validToken() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Self.readRefreshToken() else { throw Failure.badResponse("not signed in") }
        let tokens = try await tokenRequest([
            "client_id": clientID.trimmingCharacters(in: .whitespaces),
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        store(tokens)
        guard let accessToken else { throw Failure.badResponse("no access token") }
        return accessToken
    }

    private func store(_ tokens: [String: Any]) {
        accessToken = tokens["access_token"] as? String
        accessExpiry = Date().addingTimeInterval((tokens["expires_in"] as? Double) ?? 3600)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/:")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(object["error_description"] as? String ?? object["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return object
    }

    // MARK: Keychain

    nonisolated private static func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    nonisolated private static func readRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteRefreshToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

extension GoogleCalendar: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
