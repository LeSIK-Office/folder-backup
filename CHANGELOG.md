# Changelog

## 1.5.1 beta 1

- Folder-based incremental backups with shared file contents and retained versions.
- Scheduled backups, interrupted-backup recovery and version management.
- Restore complete versions or selected files into a new folder.
- System language detection and manual English, Korean, Japanese, Simplified
  Chinese and Spanish selection.
- Independent Folder Backup branding and blue folder/check icon.
- Preserve the menu bar icon when closing the main window and restore Dock
  presence when reopening the app.
- Browse large restore catalogs without repeated disk lookups for virtual paths.
- Stop promptly when storage fills or the destination disappears, preserving
  the actual cause rather than grouping it with individual-file failures.
- Reject malformed catalog paths and symbolic-link targets before filesystem use.
- Universal app packaging for Apple Silicon and Intel; Intel execution has not
  yet been tested on hardware.

This is a local beta candidate. Developer ID signing, Apple notarization and a
clean installation on another Mac remain release gates.
