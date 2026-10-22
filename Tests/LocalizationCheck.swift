import Foundation
import BackupCore

@main enum LocalizationCheck {
    static func main() throws {
        let saved = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        let nativeLanguage = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)?["AppleLanguages"]
        defer {
            if let nativeLanguage { UserDefaults.standard.set(nativeLanguage, forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            if let saved { UserDefaults.standard.set(saved, forKey: L10n.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.preferenceKey) }
        }
        if CommandLine.arguments.contains("--read-selection") {
            print(L10n.selection.rawValue)
            return
        }
        if CommandLine.arguments.contains("--bundle-probe") {
            precondition(L10n.resources.bundleURL.path.contains("/Contents/Resources/"))
            L10n.selection = .ja
            precondition(L10n.text("New Backup") == "新規バックアップ")
            print("Packaged resource lookup PASS: " + L10n.resources.bundleURL.path)
            return
        }
        if CommandLine.arguments.contains("--system-probe") {
            L10n.selection = .system
            let result: [String: Any] = ["preferred": Locale.preferredLanguages, "language": L10n.language.rawValue, "label": L10n.text("New Backup"), "date": L10n.date(Date(timeIntervalSince1970: 1792530000))]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            return
        }
        for (identifier, expected) in [("ko-KR", AppLanguage.ko), ("ja-JP", .ja), ("zh-Hans-CN", .zh), ("zh-Hant-TW", .zh), ("es-MX", .es), ("es-ES", .es), ("en-GB", .en), ("ja_JP", .ja), ("vi-VN", .en), ("fr-FR", .en), ("de-DE", .en), ("pt-BR", .en)] {
            precondition(L10n.resolve(.system, preferredLanguages: [identifier, "ko-KR"]) == expected, identifier)
            precondition(L10n.resolve(.es, preferredLanguages: [identifier]) == .es)
        }
        precondition(L10n.resolve(.system, preferredLanguages: []) == .en)
        UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
        precondition(L10n.selection == .system)
        UserDefaults.standard.set("invalid-language", forKey: L10n.preferenceKey)
        precondition(L10n.selection == .system)
        var catalogs: [String: [String: String]] = [:]
        for locale in ["en", "ko", "ja", "zh-Hans", "es"] {
            let file = L10n.resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: locale + ".lproj")!
            let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: String]
            catalogs[locale] = values
        }
        let reference = catalogs["en"]!
        precondition(reference.count == 310)
        for (_, catalog) in catalogs {
            precondition(Set(catalog.keys) == Set(reference.keys))
            for (key, value) in catalog {
                precondition(!value.isEmpty)
                precondition(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, key)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderBackup-Languages-" + UUID().uuidString)
        let source = root.appendingPathComponent("Project Atlas 日本語 한국어")
        let destination = root.appendingPathComponent("Destination")
        let restores = root.appendingPathComponent("Restores")
        for url in [source, destination, restores] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let data = Data("preserve names, contents and backup format".utf8)
        try data.write(to: source.appendingPathComponent("notes.txt"))
        let titles: [AppLanguage: String] = [.en: "New Backup", .ko: "새 백업", .ja: "新規バックアップ", .zh: "新建备份", .es: "Nueva copia"]
        for language in [AppLanguage.en, .ko, .ja, .zh, .es] {
            L10n.selection = language
            precondition(L10n.selection == language && L10n.language == language)
            precondition(L10n.text("New Backup") == titles[language], "\(language.rawValue): \(L10n.text("New Backup")), bundle=\(L10n.resources.bundleURL.path)")
            precondition(L10n.text("Manage %@", "Folder Backup").contains("Folder Backup"))
            let path = "DEV/원본/Atlas/.git/fsmonitor--daemon.ipc"
            let old = "실행용 또는 원본에서 삭제된 항목 2개 제외 · 오래된 버전 1개를 휴지통으로 옮겼습니다.\n실행용 소켓 · " + path
            let translated = L10n.message(old)
            precondition(translated.contains(path))
            precondition(translated.contains(L10n.text("Runtime or removed source items skipped: %@", "2")))
            precondition(translated.contains(L10n.text("Older backups moved to the Trash: %@", "1")))
            precondition(translated.contains(L10n.text("Runtime socket · ")))
            precondition(L10n.message("A custom diagnostic: Project Atlas") == "A custom diagnostic: Project Atlas")
            precondition(L10n.message("Unknown diagnostic · Cancel") == "Unknown diagnostic · Cancel")
            precondition(L10n.message("실행용 소켓 · DEV/원본 · Cancel").hasSuffix("DEV/원본 · Cancel"))
            precondition(L10n.message("Unknown diagnostic\nCancel") == "Unknown diagnostic\nCancel")
            let plan = UUID(); let engine = BackupEngine()
            let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
            try engine.verify(snapshotID: snapshot.id, destination: destination, planID: plan)
            let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: restores)
            let result = try Data(contentsOf: restored.appendingPathComponent(source.lastPathComponent).appendingPathComponent("notes.txt"))
            precondition(result == data)
            print("Language PASS: \(language.rawValue) · \(L10n.text("New Backup")) · \(L10n.bytes(2_301_979_749)) · names, backup, verify and restore unchanged")
        }
        L10n.selection = .es
        UserDefaults.standard.synchronize()
        let child = Process(); let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--read-selection"]; child.standardOutput = pipe
        try child.run(); child.waitUntilExit()
        let persisted = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(child.terminationStatus == 0 && persisted == "es")
        print("Language selection survives process restart: PASS")
        print("Localization PASS: 310 matching keys × 5, all placeholders, primary-language fallback, overrides, defaults, recorded messages and real fixture restores")
    }
}
