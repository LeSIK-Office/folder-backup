import SwiftUI
import BackupCore

struct ScheduleControls: View {
    @Binding var schedule: BackupSchedule
    var enabled = true
    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: {
            schedule.hour = Calendar.current.component(.hour, from: $0)
            schedule.minute = Calendar.current.component(.minute, from: $0)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L10n.text("Frequency"), selection: $schedule.frequency) {
                ForEach(BackupSchedule.Frequency.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 310)
            if [.daily, .weekly, .monthly].contains(schedule.frequency) {
                DatePicker(L10n.text("Time"), selection: time, displayedComponents: .hourAndMinute).frame(maxWidth: 310)
            }
            if schedule.frequency == .hourly {
                Picker(L10n.text("Minute of Each Hour"), selection: $schedule.minute) {
                    ForEach(0..<60) { Text(L10n.text("Minute %@", $0)).tag($0) }
                }.frame(maxWidth: 310)
            }
            if schedule.frequency == .weekly {
                Picker(L10n.text("Day of Week"), selection: $schedule.weekday) {
                    ForEach(Array([L10n.text("Sunday"), L10n.text("Monday"), L10n.text("Tuesday"), L10n.text("Wednesday"), L10n.text("Thursday"), L10n.text("Friday"), L10n.text("Saturday")].enumerated()), id: \.offset) { index, title in Text(title).tag(index + 1) }
                }.frame(maxWidth: 310)
            }
            if schedule.frequency == .monthly {
                Picker(L10n.text("Day of Month"), selection: $schedule.day) {
                    ForEach(1...31, id: \.self) { Text(L10n.text("Day %@", $0)).tag($0) }
                }.frame(maxWidth: 310)
                Text(L10n.text("If the month has no such date, the backup runs on its last day.")).font(.caption).foregroundStyle(.secondary)
            }
            if schedule.frequency == .continuous {
                Text(L10n.text("Checks every 60 seconds and backs up when changes are found.")).font(.callout)
            } else if schedule.frequency == .manual {
                Text(L10n.text("Runs when you choose Back Up Now or Resume Backup.")).font(.callout)
            }
            if !enabled {
                Label(L10n.text("Schedule off · Manual backups only"), systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let next = schedule.next(after: Date()) {
                Label(L10n.text("Next run · ") + L10n.date(next), systemImage: "calendar.badge.clock")
                    .font(.callout).foregroundStyle(BackupTheme.accent)
            }
            Text(L10n.text("Time zone: %@\nThe app must be running and the drive connected. Missed backups run when the app or Mac wakes up.", TimeZone.current.identifier))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RetentionControls: View {
    @Binding var retention: BackupRetention
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker(L10n.text("Completed Backups to Keep"), selection: $retention.mode) {
                ForEach(BackupRetention.Mode.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 330)
            if retention.mode == .recent {
                Stepper(L10n.text("Versions: %@", retention.count), value: $retention.count, in: 1...500).frame(maxWidth: 330)
            }
            Text(retention.mode == .all
                 ? L10n.text("Saves a new dated version each time. Older backups stay until you remove them.")
                 : L10n.text("After a successful backup, older versions beyond this limit move to the Trash. A failed or stopped run never replaces the last completed backup."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Label(L10n.text("Dated file lists + shared file storage"), systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("The first run saves all files. Later runs add new or changed contents; unchanged data is shared between versions. This also works on exFAT."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if retention.mode != .all {
                Label(L10n.text("Disk space is freed only after you empty the Trash."), systemImage: "trash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Label(L10n.text("Resume checks and reuses files already copied."), systemImage: "arrow.clockwise")
                .font(.callout)
            Text(L10n.text("Only changed files are copied again. Files that keep changing are retried after other files. If they still cannot be copied, the backup stays incomplete."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
