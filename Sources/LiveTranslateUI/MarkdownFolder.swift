import Foundation

/// Settings → General → "Save sessions as Markdown": each finished session is written to a folder
/// you pick (an Obsidian vault, iCloud Drive, a synced notes folder). One file per session, kept up
/// to date as the summary finishes, and renamed if the title changes.
enum MarkdownFolder {
    private static let folderKey = "markdownFolder"
    private static let namesKey = "markdownFolderNames"
    private static let queue = DispatchQueue(label: "live-translate.markdown-folder", qos: .utility)

    static var folder: URL? {
        get {
            // Checks run with a throwaway LT_STORAGE and must never write into the user's folder.
            let environment = ProcessInfo.processInfo.environment
            if environment["LT_STORAGE"] != nil {
                return environment["LT_MARKDOWN_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
            return UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: folderKey) }
    }

    /// "2026-11-07 10.02 Supplier call — January rollout.md"; characters files can't hold become dashes.
    static func fileName(for record: SessionRecord) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm"
        let title = record.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(format.string(from: record.started)) \(title.prefix(80)).md"
    }

    static func save(_ record: SessionRecord) {
        guard let folder, !record.isEmpty else { return }
        let name = fileName(for: record)
        let markdown = record.markdown()
        let id = record.id.uuidString
        queue.async {
            var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
            let url = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(markdown.utf8).write(to: url, options: .atomic)
            } catch {
                return
            }
            if let previous = names[id], previous != name {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(previous))
            }
            names[id] = name
            UserDefaults.standard.set(names, forKey: namesKey)
        }
    }

    /// Waits for pending writes, for checks.
    static func flush() { queue.sync {} }
}
