import SwiftUI
import BackupCore

struct VerificationStatusView: View {
    let result: BackupVerificationResult?
    @State private var showingDetails = false
    var body: some View {
        if let result {
            Button { showingDetails = true } label: {
                Label(result.passed ? L10n.text("Files verified OK: %@", result.files)
                      : L10n.text("Verification failed · Issues: %@", result.issues.count),
                      systemImage: result.passed ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11)).foregroundStyle(result.passed ? Color.secondary : .red)
            }.buttonStyle(.plain).help(L10n.date(result.lastVerifiedAt))
                .sheet(isPresented: $showingDetails) { VerificationResultView(result: result) }
        } else {
            Text(L10n.text("Not verified yet")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct VerificationProgressView: View {
    @ObservedObject var store: BackupStore
    let planID: UUID
    var body: some View {
        if store.verificationPlanID == planID {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let progress = store.verificationProgress, progress.total > 0 {
                        Text(L10n.text("Verifying files: %@ / %@", progress.completed, progress.total))
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    } else { ProgressView().controlSize(.small); Text(L10n.text("Reading backup catalog…")) }
                    Button(L10n.text("Cancel Verification")) { store.cancelVerification() }
                }
                if let path = store.verificationProgress?.path { Text(path).lineLimit(1).truncationMode(.middle) }
            }.font(.system(size: 11)).accessibilityIdentifier("verification-progress")
        }
    }
}

private struct VerificationResultView: View {
    let result: BackupVerificationResult
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("Verification Result")).font(.title2.bold())
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
            }
            Text(L10n.date(result.lastVerifiedAt)).foregroundStyle(.secondary)
            Text(result.passed ? L10n.text("Files verified OK: %@", result.files)
                 : L10n.text("Verification failed · Issues: %@", result.issues.count)).font(.headline)
                .foregroundStyle(result.passed ? BackupTheme.ink : .red)
            Text(L10n.text("Unique contents read in this run: %@", result.uniqueObjectsChecked)).font(.callout)
            Text(L10n.text("SHA-256 checks read saved contents without creating a restore folder. Backup data and source files are never changed. Results are saved only in this Mac’s plan settings."))
                .font(.callout).foregroundStyle(.secondary)
            if result.passed { Spacer() }
            else {
                List(result.issues) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(issue.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text(L10n.message(issue.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }.padding(24).frame(width: 650, height: 440).preferredColorScheme(.light)
    }
}
