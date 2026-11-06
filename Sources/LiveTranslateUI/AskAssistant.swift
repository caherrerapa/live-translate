import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Provider and secrets

/// Who answers Ask and writes the summary. On device never sends anything anywhere; ChatGPT and
/// Claude get the question and the transcript. Translation always stays on the device.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case onDevice
    case chatGPT
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice:
            #if os(macOS)
            return "On this Mac"
            #else
            return "On device"
            #endif
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    /// Where an API key comes from, for the Connect sheet.
    var keyPage: URL? {
        switch self {
        case .onDevice: return nil
        case .chatGPT: return URL(string: "https://platform.openai.com/api-keys")
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")
        }
    }

    var keyAccount: String { "key.\(rawValue)" }

    /// Read from any thread (the notes pass runs on a background queue).
    static var selected: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .onDevice
    }
}

/// Keychain items for API keys and MCP tokens. Never written to disk in the clear.
enum SecretStore {
    private static let service = "com.caherrerapa.LiveTranslate.ai"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: Connections

/// A remote MCP server Ask can read from and add to: Notion, Linear, Slack, Google Drive, or any URL.
struct MCPConnection: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var symbol: String
    var enabled = true
    var connected = false
    var tokenEndpoint: String?
    var clientID: String?
    var expiry: Date?
    /// Set for presets whose server has no client registration (Slack): the user supplies a client ID.
    var needsClientID = false

    var accessAccount: String { "mcp.\(id).access" }
    var refreshAccount: String { "mcp.\(id).refresh" }

    /// Tool-friendly name for the API (letters, digits, dashes).
    var serverName: String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static let presets: [MCPConnection] = [
        MCPConnection(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", symbol: "doc.text"),
        MCPConnection(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", symbol: "checkmark.square"),
        // No official Google Drive MCP server: Connect asks for the URL of the one you use.
        MCPConnection(id: "drive", name: "Google Drive", url: "", symbol: "folder"),
        MCPConnection(id: "slack", name: "Slack", url: "https://mcp.slack.com/mcp", symbol: "bubble.left", needsClientID: true),
    ]
}

/// The chosen provider, its keys, and the MCP connections, shared by Ask, the summary, and Settings.
@MainActor
final class AIConnections: NSObject, ObservableObject {
    static let shared = AIConnections()

    @Published var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider") }
    }
    @Published private(set) var connections: [MCPConnection]
    @Published private(set) var keys: Set<AIProvider> = []
    @Published private(set) var connecting: String?

    private static let connectionsKey = "mcpConnections"
    private var authSession: ASWebAuthenticationSession?

    override init() {
        provider = AIProvider.selected
        let saved = (UserDefaults.standard.data(forKey: Self.connectionsKey))
            .flatMap { try? JSONDecoder().decode([MCPConnection].self, from: $0) } ?? []
        // Presets first, in the design's order; anything the user added after them.
        var merged = MCPConnection.presets.map { preset in saved.first { $0.id == preset.id } ?? preset }
        merged += saved.filter { item in !MCPConnection.presets.contains { $0.id == item.id } }
        connections = merged
        super.init()
        keys = Set(AIProvider.allCases.filter { SecretStore.get($0.keyAccount) != nil })
    }

    func hasKey(_ provider: AIProvider) -> Bool { provider == .onDevice || keys.contains(provider) }

    func setKey(_ key: String?, for provider: AIProvider) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretStore.set(trimmed, for: provider.keyAccount)
        if let trimmed, !trimmed.isEmpty { keys.insert(provider) } else { keys.remove(provider) }
        if trimmed?.isEmpty != false, self.provider == provider { self.provider = .onDevice }
    }

    /// Connected and switched on: what Ask passes to ChatGPT or Claude.
    var active: [MCPConnection] { connections.filter { $0.connected && $0.enabled && !$0.url.isEmpty } }

    func setEnabled(_ id: String, _ on: Bool) {
        update(id) { $0.enabled = on }
    }

    func disconnect(_ id: String) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        SecretStore.set(nil, for: connection.accessAccount)
        SecretStore.set(nil, for: connection.refreshAccount)
        if MCPConnection.presets.contains(where: { $0.id == id }) {
            update(id) { $0.connected = false; $0.expiry = nil }
        } else {
            connections.removeAll { $0.id == id }
            save()
        }
    }

    /// Adds a server by URL. With a token it is connected at once; without one, it signs in by OAuth.
    func add(name: String, url: String, token: String?, clientID: String?) async throws {
        let id = MCPConnection.presets.first { $0.name == name && $0.url.isEmpty }?.id ?? "custom-\(UUID().uuidString.prefix(8))"
        var connection = connections.first { $0.id == id }
            ?? MCPConnection(id: id, name: name, url: url, symbol: "server.rack")
        connection.name = name
        connection.url = url
        connection.clientID = clientID?.isEmpty == false ? clientID : connection.clientID
        if let index = connections.firstIndex(where: { $0.id == id }) { connections[index] = connection } else { connections.append(connection) }
        save()
        if let token, !token.isEmpty {
            SecretStore.set(token, for: connection.accessAccount)
            update(id) { $0.connected = true; $0.expiry = nil }
        } else {
            try await connect(id)
        }
    }

    /// The MCP authorization flow: discover the server's OAuth server, register this app when the
    /// server allows it, sign in in the system browser sheet with PKCE, and keep the tokens.
    func connect(_ id: String, clientID: String? = nil) async throws {
        guard var connection = connections.first(where: { $0.id == id }), let server = URL(string: connection.url) else {
            throw AskError.message("Add the server's URL first.")
        }
        connecting = id
        defer { connecting = nil }
        let discovery = try await MCPAuth.discover(server: server)
        var client = clientID ?? connection.clientID
        if client == nil {
            guard let registration = discovery.registrationEndpoint else {
                throw AskError.needsClientID(connection.name)
            }
            client = try await MCPAuth.register(at: registration)
        }
        guard let client else { throw AskError.needsClientID(connection.name) }
        let tokens = try await signIn(discovery: discovery, clientID: client, resource: server)
        SecretStore.set(tokens.access, for: connection.accessAccount)
        if let refresh = tokens.refresh { SecretStore.set(refresh, for: connection.refreshAccount) }
        connection.clientID = client
        connection.tokenEndpoint = discovery.tokenEndpoint.absoluteString
        connection.expiry = tokens.expiry
        connection.connected = true
        connection.enabled = true
        if let index = connections.firstIndex(where: { $0.id == id }) { connections[index] = connection }
        save()
    }

    /// A token that is still good, refreshed when it is about to expire.
    func token(for connection: MCPConnection) async -> String? {
        if let expiry = connection.expiry, expiry < Date().addingTimeInterval(60),
           let refresh = SecretStore.get(connection.refreshAccount),
           let endpoint = connection.tokenEndpoint.flatMap(URL.init(string:)),
           let client = connection.clientID,
           let tokens = try? await MCPAuth.refresh(refresh, clientID: client, tokenEndpoint: endpoint, resource: connection.url) {
            SecretStore.set(tokens.access, for: connection.accessAccount)
            if let newRefresh = tokens.refresh { SecretStore.set(newRefresh, for: connection.refreshAccount) }
            update(connection.id) { $0.expiry = tokens.expiry }
        }
        return SecretStore.get(connection.accessAccount)
    }

    private func signIn(discovery: MCPAuth.Discovery, clientID: String, resource: URL) async throws -> MCPAuth.Tokens {
        let verifier = MCPAuth.randomURLSafe(48)
        let state = MCPAuth.randomURLSafe(16)
        var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: MCPAuth.redirectURI),
            .init(name: "code_challenge", value: MCPAuth.challenge(verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource.absoluteString),
        ]
        if let scope = discovery.scope { items.append(.init(name: "scope", value: scope)) }
        components.queryItems = items
        guard let url = components.url else { throw AskError.message("The sign-in address is not valid.") }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MCPAuth.scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AskError.message("Sign-in was cancelled."))
                } else {
                    continuation.resume(throwing: error ?? AskError.message("Sign-in did not finish."))
                }
            }
            session.presentationContextProvider = self
            authSession = session
            session.start()
        }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let problem = query.first(where: { $0.name == "error" })?.value {
            throw AskError.message("Sign-in failed: \(problem)")
        }
        guard query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else {
            throw AskError.message("Sign-in returned no code.")
        }
        return try await MCPAuth.exchange(code: code, verifier: verifier, clientID: clientID,
                                          tokenEndpoint: discovery.tokenEndpoint, resource: resource.absoluteString)
    }

    private func update(_ id: String, _ change: (inout MCPConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: Self.connectionsKey)
        }
    }
}

extension AIConnections: ASWebAuthenticationPresentationContextProviding {
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

enum AskError: LocalizedError {
    case message(String)
    case needsClientID(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .needsClientID(let name):
            return "\(name) doesn't let apps register themselves. Add it with Add MCP server… and your own OAuth client ID."
        }
    }
}

/// OAuth for MCP servers (the MCP authorization spec): protected-resource metadata, authorization
/// server metadata, dynamic client registration, and PKCE code exchange.
enum MCPAuth {
    static let scheme = "livetranslate"
    static let redirectURI = "livetranslate://oauth/callback"

    struct Discovery {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scope: String?
    }

    struct Tokens {
        var access: String
        var refresh: String?
        var expiry: Date?
    }

    static func discover(server: URL) async throws -> Discovery {
        // An unauthenticated request answers 401 and points at the resource's metadata.
        var probe = URLRequest(url: server)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Live Translate","version":"1"}}}"#.utf8)
        probe.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: probe)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        let origin = URL(string: "\(server.scheme ?? "https")://\(server.host ?? "")")!
        let metadataURL = value(of: "resource_metadata", in: header).flatMap(URL.init(string:))
            ?? origin.appendingPathComponent(".well-known/oauth-protected-resource")
        let scope = value(of: "scope", in: header)
        let resource = try await json(metadataURL)
        let issuer = (resource["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:)) ?? origin
        var server = try? await json(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
        if server?["authorization_endpoint"] == nil {
            server = try? await json(issuer.appendingPathComponent(".well-known/openid-configuration"))
        }
        guard let authorize = (server?["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (server?["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw AskError.message("This server doesn't describe how to sign in.")
        }
        let supported = (resource["scopes_supported"] as? [String])?.joined(separator: " ")
        return Discovery(
            authorizationEndpoint: authorize,
            tokenEndpoint: token,
            registrationEndpoint: (server?["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            // The header's scope when given; else the advertised list, unless it is enormous (Slack).
            scope: scope ?? ((supported?.count ?? 0) < 200 ? supported : nil)
        )
    }

    static func register(at endpoint: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Live Translate",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let id = object["client_id"] as? String else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AskError.message("The server refused to register Live Translate (\(object["error_description"] as? String ?? "HTTP \(status)")).")
        }
        return id
    }

    static func exchange(code: String, verifier: String, clientID: String, tokenEndpoint: URL, resource: String) async throws -> Tokens {
        try await token(tokenEndpoint, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": resource,
        ])
    }

    static func refresh(_ refresh: String, clientID: String, tokenEndpoint: URL, resource: String) async throws -> Tokens {
        try await token(tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
            "resource": resource,
        ])
    }

    private static func token(_ endpoint: URL, _ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = object["access_token"] as? String else {
            throw AskError.message("Sign-in failed: \(object["error_description"] as? String ?? object["error"] as? String ?? "no access token")")
        }
        let expiry = (object["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return Tokens(access: access, refresh: object["refresh_token"] as? String, expiry: expiry)
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `name="value"` from a WWW-Authenticate header.
    static func value(of name: String, in header: String) -> String? {
        guard let range = header.range(of: "\(name)=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: Ask

struct AskCitation: Identifiable, Equatable {
    var id: String { turnID.isEmpty ? clock : turnID }
    var clock: String
    var speaker: String
    var turnID: String
}

/// What the assistant did in a connected app: "Notion · 2 tasks added", the items, and where.
struct AskAction: Identifiable, Equatable {
    var id = UUID()
    var app: String
    var result: String
    var items: [String]
    var location: String
    var link: URL?
    var failed = false
}

struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant, failure }
    var id = UUID()
    var role: Role
    var text: String
    var citations: [AskCitation] = []
    var actions: [AskAction] = []
}

/// One conversation per session about that session's transcript.
@MainActor
final class AskEngine: ObservableObject {
    static let shared = AskEngine()

    @Published private(set) var threads: [UUID: [AskMessage]] = [:]
    @Published private(set) var thinking: Set<UUID> = []

    func messages(for session: UUID) -> [AskMessage] { threads[session] ?? [] }

    func ask(_ question: String, about record: SessionRecord) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking.contains(record.id) else { return }
        let session = record.id
        threads[session, default: []].append(AskMessage(role: .user, text: text))
        thinking.insert(session)
        let history = threads[session] ?? []
        let connections = AIConnections.shared
        let provider = connections.provider
        let active = provider == .onDevice ? [] : connections.active
        Task {
            var servers: [(MCPConnection, String)] = []
            for connection in active {
                if let token = await connections.token(for: connection) { servers.append((connection, token)) }
            }
            let reply: AskMessage
            do {
                let answer = try await AskBackends.answer(
                    provider: provider, record: record, history: history, servers: servers
                )
                reply = AskParsing.message(from: answer.text, toolActions: answer.actions, record: record)
            } catch {
                reply = AskMessage(role: .failure, text: error.localizedDescription)
            }
            threads[session, default: []].append(reply)
            thinking.remove(session)
        }
    }

    func clear(_ session: UUID) {
        threads[session] = nil
    }

    #if DEBUG
    /// The design's conversation, for screenshots.
    func loadDemo(for record: SessionRecord) {
        let permit = record.turns.first { $0.source.hasPrefix("Probably by the end of next week") }
        let clock = permit.map { AskParsing.clock(record, $0) } ?? "10:05"
        threads[record.id] = [
            AskMessage(role: .user, text: "What did we agree about store three?"),
            AskMessage(role: .assistant,
                       text: "Store three opens once the building permit arrives, expected by the end of next week. If it slips, the opening moves to early February rather than rushing the install.",
                       citations: [AskCitation(clock: clock, speaker: permit?.speaker ?? "Speaker 2", turnID: permit?.id ?? "")]),
            AskMessage(role: .user, text: "Add the action items to my Notion"),
            AskMessage(role: .assistant, text: "", actions: [
                AskAction(app: "Notion", result: "2 tasks added",
                          items: ["Send updated timeline · Fri", "Share permit decision · Next week"],
                          location: "Store rollout › Tasks", link: URL(string: "https://www.notion.so")),
            ]),
        ]
    }
    #endif
}

/// The prompt, and turning the model's reply into text, citation chips and action cards.
enum AskParsing {
    static func clock(_ record: SessionRecord, _ turn: SavedTurn) -> String {
        record.started.addingTimeInterval(turn.start).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func system(for record: SessionRecord, apps: [String], budget: Int) -> String {
        var lines = [
            "You answer questions about one meeting, using its transcript below. Live Translate recorded it and translated each turn.",
            "Be brief and concrete. Answer in the language of the question.",
            "When something comes from a particular turn, cite that turn's time in square brackets, like [10:05]. Only cite times that appear in the transcript.",
            "If the transcript doesn't say, say so instead of guessing.",
        ]
        if apps.isEmpty {
            lines.append("You can't act in other apps from here; if asked to, say that a connection needs ChatGPT or Claude in Settings → Connections.")
        } else {
            lines.append("You can read from and add to these connected apps with their tools: \(apps.joined(separator: ", ")). Use them when the user asks you to do something there.")
            lines.append("After acting in an app, end your reply with one line in exactly this form (no other text on it):")
            lines.append("ACTION: <app name> | <short result, e.g. 2 tasks added> | <item one>; <item two> | <where, e.g. Store rollout › Tasks> | <link, or nothing>")
        }
        lines += ["", "# Meeting", record.displayTitle, record.started.formatted(date: .complete, time: .shortened)
                  + " · \(record.direction.source.title) → \(record.direction.target.title) · \(SessionRecord.durationText(record.duration))"]
        if let meeting = record.meeting { lines.append(meeting.promptLine) }
        let summary = record.note.summary.map(\.text).joined(separator: " ")
        if !summary.isEmpty { lines += ["", "# Summary so far", summary] }
        if !record.note.actions.isEmpty {
            lines += ["", "# Action items so far"] + record.note.actions.map { "- \($0.text)" + ($0.speaker.isEmpty ? "" : " (\($0.speaker))") }
        }
        if !record.userNotes.isEmpty { lines += ["", "# The user's notes", record.userNotes] }
        lines += ["", "# Transcript (time, speaker, original, translation)"]
        // The newest turns matter most; an on-device model only fits the end of a long meeting.
        var turns: [String] = []
        var used = lines.joined(separator: "\n").count
        for turn in record.turns.reversed() {
            let speaker = turn.speaker.isEmpty ? "Speaker" : turn.speaker
            let line = "[\(clock(record, turn))] \(speaker): \(turn.source)" + (turn.translation.isEmpty ? "" : " / \(turn.translation)")
            if used + line.count > budget { turns.append("(earlier turns omitted)"); break }
            used += line.count + 1
            turns.append(line)
        }
        lines += turns.reversed()
        if record.turns.isEmpty { lines.append("(nothing has been said yet)") }
        return lines.joined(separator: "\n")
    }

    static func message(from raw: String, toolActions: [AskAction], record: SessionRecord) -> AskMessage {
        var body: [String] = []
        var actions: [AskAction] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("ACTION:") {
                let parts = trimmed.dropFirst("ACTION:".count).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let app = parts.first, !app.isEmpty else { continue }
                let items = parts.count > 2 ? parts[2].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                let link = parts.count > 4 ? URL(string: parts[4]).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } : nil
                actions.append(AskAction(app: app, result: parts.count > 1 ? parts[1] : "Done", items: items,
                                         location: parts.count > 3 ? parts[3] : "", link: link))
            } else {
                body.append(line)
            }
        }
        // Tool calls the model made but didn't summarize still show up, so nothing happens unseen.
        if actions.isEmpty { actions = toolActions } else {
            for failed in toolActions where failed.failed && !actions.contains(where: { $0.app == failed.app }) {
                actions.append(failed)
            }
        }
        var text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var citations: [AskCitation] = []
        let pattern = try? NSRegularExpression(pattern: #"\s?\[(\d{1,2}:\d{2})\]"#)
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern?.matches(in: text, range: range) ?? [] {
            guard let clockRange = Range(match.range(at: 1), in: text) else { continue }
            let clock = String(text[clockRange])
            let padded = clock.count == 4 ? "0" + clock : clock
            guard !citations.contains(where: { $0.clock == padded }) else { continue }
            let turn = record.turns.first { Self.clock(record, $0) == padded }
            citations.append(AskCitation(clock: padded, speaker: turn?.speaker ?? "", turnID: turn?.id ?? ""))
        }
        if let pattern {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            // "next week, [10:05]." leaves "next week,." behind.
            text = text.replacingOccurrences(of: #"[,;]\s*([.!?])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        }
        return AskMessage(role: .assistant, text: text, citations: Array(citations.prefix(3)), actions: actions)
    }
}

/// The three ways to answer. Claude and ChatGPT reach the connected apps themselves through their
/// APIs' remote-MCP support; this app only hands over each server's URL and the user's token.
enum AskBackends {
    struct Answer {
        var text: String
        var actions: [AskAction]
    }

    static let claudeModel = "claude-opus-5-5"
    static let openAIModel = "gpt-5"

    static func answer(provider: AIProvider, record: SessionRecord, history: [AskMessage], servers: [(MCPConnection, String)]) async throws -> Answer {
        let conversation = history.filter { $0.role != .failure }
        switch provider {
        case .claude:
            guard let key = SecretStore.get(provider.keyAccount) else { throw AskError.message("Connect Claude in Settings → Connections first.") }
            let system = AskParsing.system(for: record, apps: servers.map(\.0.name), budget: 400_000)
            return try await claude(key: key, system: system, conversation: conversation, servers: servers)
        case .chatGPT:
            guard let key = SecretStore.get(provider.keyAccount) else { throw AskError.message("Connect ChatGPT in Settings → Connections first.") }
            let system = AskParsing.system(for: record, apps: servers.map(\.0.name), budget: 400_000)
            return try await openAI(key: key, system: system, conversation: conversation, servers: servers)
        case .onDevice:
            return Answer(text: try await onDevice(record: record, conversation: conversation), actions: [])
        }
    }

    // MARK: Claude (Messages API, MCP connector)

    static func claude(key: String, system: String, conversation: [AskMessage], servers: [(MCPConnection, String)]) async throws -> Answer {
        var body: [String: Any] = [
            "model": claudeModel,
            "max_tokens": 16000,
            "system": system,
            "messages": conversation.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
            "output_config": ["effort": "medium"],
            // Routes a declined request to another model instead of failing it.
            "fallbacks": "default",
        ]
        var betas = ["server-side-fallback-2026-07-01"]
        if !servers.isEmpty {
            betas.append("mcp-client-2025-11-20")
            body["mcp_servers"] = servers.map { connection, token in
                ["type": "url", "url": connection.url, "name": connection.serverName, "authorization_token": token]
            }
            body["tools"] = servers.map { connection, _ in ["type": "mcp_toolset", "mcp_server_name": connection.serverName] }
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await send(request, provider: "Claude")
        if object["stop_reason"] as? String == "refusal" {
            throw AskError.message("Claude declined to answer this one.")
        }
        var texts: [String] = []
        var calls: [String: (server: String, tool: String)] = [:]
        var actions: [AskAction] = []
        for block in object["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "mcp_tool_use":
                if let id = block["id"] as? String {
                    calls[id] = (block["server_name"] as? String ?? "", block["name"] as? String ?? "")
                }
            case "mcp_tool_result":
                let call = calls[block["tool_use_id"] as? String ?? ""]
                let app = servers.first { $0.0.serverName == call?.server }?.0.name ?? call?.server ?? "App"
                let failed = block["is_error"] as? Bool ?? false
                note(app: app, tool: call?.tool ?? "", failed: failed, into: &actions)
            default:
                break
            }
        }
        return Answer(text: texts.joined(separator: "\n"), actions: actions)
    }

    // MARK: ChatGPT (Responses API, remote MCP tools)

    static func openAI(key: String, system: String, conversation: [AskMessage], servers: [(MCPConnection, String)]) async throws -> Answer {
        var body: [String: Any] = [
            "model": openAIModel,
            "instructions": system,
            "input": conversation.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
        ]
        if !servers.isEmpty {
            body["tools"] = servers.map { connection, token in
                [
                    "type": "mcp",
                    "server_label": connection.serverName,
                    "server_url": connection.url,
                    "headers": ["Authorization": "Bearer \(token)"],
                    "require_approval": "never",
                ] as [String: Any]
            }
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await send(request, provider: "ChatGPT")
        var texts: [String] = []
        var actions: [AskAction] = []
        for item in object["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                    if let text = part["text"] as? String { texts.append(text) }
                }
            case "mcp_call":
                let label = item["server_label"] as? String ?? ""
                let app = servers.first { $0.0.serverName == label }?.0.name ?? label
                note(app: app, tool: item["name"] as? String ?? "", failed: item["error"] is String, into: &actions)
            default:
                break
            }
        }
        return Answer(text: texts.joined(separator: "\n"), actions: actions)
    }

    /// Reads that list nothing; writes become "Notion · 2 changes".
    private static func note(app: String, tool: String, failed: Bool, into actions: inout [AskAction]) {
        let reads = ["search", "fetch", "get", "list", "read", "find", "query"]
        let isRead = reads.contains { tool.lowercased().contains($0) }
        if isRead && !failed { return }
        if let index = actions.firstIndex(where: { $0.app == app && $0.failed == failed }) {
            actions[index].items.append(humanize(tool))
            actions[index].result = failed ? "Didn't finish" : "\(actions[index].items.count) changes"
        } else {
            actions.append(AskAction(app: app, result: failed ? "Didn't finish" : "1 change", items: [humanize(tool)], location: "", failed: failed))
        }
    }

    private static func humanize(_ tool: String) -> String {
        let words = tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func send(_ request: URLRequest, provider: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            if http.statusCode == 401 { throw AskError.message("\(provider) didn't accept the API key. Check it in Settings → Connections.") }
            throw AskError.message("\(provider): \(message)")
        }
        return object
    }

    // MARK: On device

    /// Apple Intelligence when the system has it; on the Mac otherwise the notes model.
    static func onDevice(record: SessionRecord, conversation: [AskMessage]) async throws -> String {
        // The on-device model's context is small: the end of the transcript plus the conversation.
        let system = AskParsing.system(for: record, apps: [], budget: 7_000)
        let dialogue = conversation.suffix(6).map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: system)
            do {
                return try await session.respond(to: dialogue + "\nAssistant:").content
            } catch {
                #if os(iOS)
                throw AskError.message("Apple Intelligence couldn't answer: \(error.localizedDescription)")
                #endif
            }
        }
        #endif
        #if os(macOS)
        let prompt = system + "\n\n" + dialogue + "\nAssistant:"
        let text = await Task.detached(priority: .userInitiated) {
            AskLocalModel.client.complete(prompt, maxTokens: 400)
        }.value
        guard !text.isEmpty else { throw AskError.message("The model on this Mac isn't installed yet. Open Manage Languages, or choose ChatGPT or Claude.") }
        return text
        #else
        throw AskError.message("On-device answers need Apple Intelligence. Turn it on in Settings, or choose ChatGPT or Claude.")
        #endif
    }

    /// The summary pass with ChatGPT or Claude, when chosen. Nil means "use the on-device model".
    /// Called on the notes queue, so it waits for the answer here.
    nonisolated static func cloudDraftText(prompt: String) -> String? {
        let provider = AIProvider.selected
        guard provider != .onDevice, let key = SecretStore.get(provider.keyAccount) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = TextBox()
        Task.detached {
            let conversation = [AskMessage(role: .user, text: prompt)]
            let system = "You write a live meeting note as JSON. Follow the user's format exactly."
            let answer = try? await (provider == .claude
                ? claude(key: key, system: system, conversation: conversation, servers: [])
                : openAI(key: key, system: system, conversation: conversation, servers: []))
            box.set(answer?.text)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else { return nil }
        return box.get()
    }

    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ text: String?) { lock.lock(); value = text; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

#if os(macOS)
/// Ask's local fallback shares the notes model's process with the summary; the controller sets it.
enum AskLocalModel {
    nonisolated(unsafe) static var client = TyphoonNotesClient()
}
#endif
