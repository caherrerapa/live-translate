#if os(macOS)
import Foundation

/// `LiveTranslate --mcp`: a Model Context Protocol server over stdio, so the Claude app you are
/// signed into (Claude Desktop, Claude Code) can read your sessions and act on them with its own
/// connectors. Read-only: it lists, reads and searches the session files this Mac already keeps.
/// The session in progress is included, because the app saves it every few seconds.
enum MCPServer {
    static let name = "live-translate"
    static let protocolVersion = "2025-06-18"

    static func run(storage: URL = AppStorageRoot.url()) {
        let store = SessionStore(storage: storage)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let reply = handle(message, store: store) { send(reply) }
        }
    }

    /// One JSON-RPC message in, at most one reply out. Notifications get no reply.
    static func handle(_ message: [String: Any], store: SessionStore) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return result([
                "protocolVersion": asked ?? protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": "Sessions recorded by Live Translate on this Mac: live translated conversations with a transcript in two languages and a summary. Use list_sessions or search_sessions to find one, then get_session for the full Markdown. \"latest\" is the most recent session, including one still being recorded.",
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, failed) = call(name, arguments, records: store.loadAll())
            return result(["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_sessions",
            "description": "List recent Live Translate sessions, newest first: id, title, date, length, languages and number of turns.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "description": "How many sessions to list (default 20)."]],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_session",
            "description": "One session as Markdown: summary, key points, action items, your notes and the full bilingual transcript.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "A session id from list_sessions, or \"latest\"."]],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_transcript",
            "description": "Only the transcript of one session, in the original language, the translation, or both line by line.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "A session id from list_sessions, or \"latest\"."],
                    "part": ["type": "string", "enum": ["original", "translation", "both"], "description": "Which text (default both)."],
                    "timestamps": ["type": "boolean", "description": "Prefix each turn with its time (default false)."],
                ],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_sessions",
            "description": "Find sessions whose title, notes or transcript contain the given words.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Words to look for."]],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    /// Returns the tool's text and whether it failed.
    static func call(_ name: String, _ arguments: [String: Any], records: [SessionRecord]) -> (String, Bool) {
        let usable = records.filter { !$0.isEmpty }
        switch name {
        case "list_sessions":
            let limit = max(1, (arguments["limit"] as? Int) ?? 20)
            guard !usable.isEmpty else { return ("No sessions yet.", false) }
            return (usable.prefix(limit).map(line).joined(separator: "\n"), false)
        case "get_session":
            guard let record = find(arguments["id"] as? String, in: usable) else { return (missing(arguments["id"]), true) }
            return (record.markdown(), false)
        case "get_transcript":
            guard let record = find(arguments["id"] as? String, in: usable) else { return (missing(arguments["id"]), true) }
            let kind: SessionCopyKind
            switch arguments["part"] as? String {
            case "original": kind = .original
            case "translation": kind = .translation
            default: kind = .bilingual
            }
            var options = SessionCopyOptions()
            options.timestamps = arguments["timestamps"] as? Bool ?? false
            return (record.copyText(kind, options: options), false)
        case "search_sessions":
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return ("Give some words to search for.", true) }
            let hits = usable.filter { $0.matches(query) }
            guard !hits.isEmpty else { return ("No session mentions \"\(query)\".", false) }
            return (hits.prefix(20).map(line).joined(separator: "\n"), false)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private static func find(_ id: String?, in records: [SessionRecord]) -> SessionRecord? {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        if id.lowercased() == "latest" { return records.first }
        return records.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func missing(_ id: Any?) -> String {
        "No session with id \(id.map { "\($0)" } ?? "(none)"). Use list_sessions to see the ids."
    }

    private static func line(_ record: SessionRecord) -> String {
        let date = record.started.formatted(date: .abbreviated, time: .shortened)
        return "- \(record.id.uuidString) · \(record.displayTitle) · \(date) · \(SessionRecord.durationText(record.duration)) · \(record.directionShort) · \(record.turns.count) \(record.turns.count == 1 ? "turn" : "turns")"
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

/// Registers the server with Claude Desktop and offers the Claude Code command.
enum ClaudeConnection {
    /// The binary Claude launches: this app, with `--mcp`.
    static var executable: String { Bundle.main.executablePath ?? "/Applications/LiveTranslate.app/Contents/MacOS/LiveTranslate" }

    static var desktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user \(MCPServer.name) -- \"\(executable)\" --mcp"
    }

    static var isInDesktopConfig: Bool {
        guard let data = try? Data(contentsOf: desktopConfig),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        return servers[MCPServer.name] != nil
    }

    /// Adds or updates this app's entry, keeping every other setting in the file.
    static func addToDesktopConfig() throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: desktopConfig) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[MCPServer.name] = ["command": executable, "args": ["--mcp"]]
        object["mcpServers"] = servers
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: desktopConfig, options: .atomic)
    }
}
#endif
