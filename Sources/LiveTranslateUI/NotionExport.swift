import Foundation
import Security

/// Sends a session's text (note, your notes, transcript) to a Notion page when the
/// user presses Export to Notion. Never automatic, never audio. The integration
/// token lives in the Keychain; the parent page id in user defaults.
enum NotionExport {
    struct Settings: Equatable {
        var token: String
        var parentPageID: String

        var isComplete: Bool {
            !token.trimmingCharacters(in: .whitespaces).isEmpty && NotionExport.pageID(from: parentPageID) != nil
        }
    }

    enum Failure: LocalizedError {
        case notConfigured
        case api(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Add a Notion integration token and a parent page first."
            case .api(let code, let message): return "Notion answered \(code): \(message)"
            }
        }
    }

    private static let service = "com.caherrerapa.LiveTranslate.notion"
    private static let parentKey = "notionParentPage"

    static func load() -> Settings {
        Settings(token: readToken() ?? "", parentPageID: UserDefaults.standard.string(forKey: parentKey) ?? "")
    }

    static func save(_ settings: Settings) {
        UserDefaults.standard.set(settings.parentPageID, forKey: parentKey)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard !settings.token.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(settings.token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Accepts a bare id, a dashed id, or a notion.so page URL.
    static func pageID(from text: String) -> String? {
        let hex = text.lowercased().filter { $0.isHexDigit }
        guard hex.count >= 32 else { return nil }
        return String(hex.suffix(32))
    }

    /// Creates the page and returns its URL.
    static func export(_ record: SessionRecord, settings: Settings) async throws -> URL? {
        guard settings.isComplete, let parent = pageID(from: settings.parentPageID) else { throw Failure.notConfigured }
        let blocks = self.blocks(for: record)
        let first = Array(blocks.prefix(100))
        let body: [String: Any] = [
            "parent": ["page_id": parent],
            "properties": ["title": ["title": richText(record.displayTitle)]],
            "children": first,
        ]
        let created = try await call("POST", "pages", body: body, token: settings.token)
        // Notion takes at most 100 blocks per request; the rest are appended in batches.
        if let pageID = created["id"] as? String {
            var rest = Array(blocks.dropFirst(100))
            while !rest.isEmpty {
                let batch = Array(rest.prefix(100))
                rest.removeFirst(batch.count)
                _ = try await call("PATCH", "blocks/\(pageID)/children", body: ["children": batch], token: settings.token)
            }
        }
        return (created["url"] as? String).flatMap(URL.init(string:))
    }

    private static func call(_ method: String, _ path: String, body: [String: Any], token: String) async throws -> [String: Any] {
        var base = "https://api.notion.com/v1/"
        #if DEBUG
        // Checks run against a local stand-in for Notion's API.
        if let override = ProcessInfo.processInfo.environment["LT_NOTION_API"], !override.isEmpty { base = override }
        #endif
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.api(http.statusCode, object["message"] as? String ?? "request failed")
        }
        return object
    }

    // MARK: Blocks

    static func blocks(for record: SessionRecord) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(block("paragraph", "\(record.started.formatted(date: .abbreviated, time: .shortened)) · \(record.directionShort) · \(SessionRecord.durationText(record.duration)) · \(record.speakerCount) speakers"))
        let summary = record.note.summary.map(\.text).joined(separator: " ")
        if !summary.isEmpty {
            blocks.append(block("heading_2", "Summary"))
            blocks.append(block("paragraph", summary))
        }
        let points = record.note.decisions + record.note.openQuestions + record.note.highlights
        if !points.isEmpty {
            blocks.append(block("heading_2", "Key points"))
            blocks += points.map { block("bulleted_list_item", $0.text) }
        }
        if !record.note.actions.isEmpty {
            blocks.append(block("heading_2", "Action items"))
            for action in record.note.actions {
                let text = action.speaker.isEmpty ? action.text : "\(action.text) (\(action.speaker))"
                blocks.append(["object": "block", "type": "to_do", "to_do": ["rich_text": richText(text), "checked": record.checkedActions.contains(action.id)]])
            }
        }
        let own = record.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            blocks.append(block("heading_2", "Notes"))
            blocks.append(block("paragraph", own))
        }
        if !record.turns.isEmpty {
            blocks.append(block("heading_2", "Transcript"))
            for turn in record.turns {
                let clock = record.started.addingTimeInterval(turn.start).formatted(date: .omitted, time: .shortened)
                let head = turn.speaker.isEmpty ? clock : "\(turn.speaker) · \(clock)"
                blocks.append(block("paragraph", "\(head)\n\(turn.source)" + (turn.translation.isEmpty ? "" : "\n\(turn.translation)")))
            }
        }
        return blocks
    }

    private static func block(_ type: String, _ text: String) -> [String: Any] {
        ["object": "block", "type": type, type: ["rich_text": richText(text)]]
    }

    /// Notion caps one text run at 2000 characters.
    private static func richText(_ text: String) -> [[String: Any]] {
        var runs: [[String: Any]] = []
        var rest = Substring(text)
        repeat {
            let piece = rest.prefix(2000)
            rest = rest.dropFirst(piece.count)
            runs.append(["type": "text", "text": ["content": String(piece)]])
        } while !rest.isEmpty
        return runs
    }
}
