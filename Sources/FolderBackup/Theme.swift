import SwiftUI
import AppKit
import BackupCore

enum BackupTheme {
    static let accent = Color(red: 0.06, green: 0.27, blue: 0.56)
    static let background = Color(red: 0.96, green: 0.975, blue: 0.99)
    static let ink = Color(red: 0.15, green: 0.19, blue: 0.26)
    static let border = Color(red: 0.86, green: 0.90, blue: 0.95)
}

struct BackupButton: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(secondary ? BackupTheme.accent : .white)
            .background(secondary ? Color.white : BackupTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(secondary ? BackupTheme.border : .clear, lineWidth: 1))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct BackupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BackupTheme.border, lineWidth: 1))
    }
}

struct BackupMark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "FolderBackupMark", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(BackupTheme.accent).accessibilityHidden(true)
        }
    }
}

func pickFolders(title: String, multiple: Bool = false) -> [URL] {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = L10n.text("Choose")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = multiple
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.urls : []
}

func byteString(_ value: Int64) -> String {
    L10n.bytes(value)
}
