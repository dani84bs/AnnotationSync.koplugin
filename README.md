# AnnotationSync.koplugin

> **Sync your KOReader annotations everywhere!**
>
> Never lose a highlight or note again—AnnotationSync keeps your reading life in sync across all your devices.

## 🚀 Features

- **Cloud sync for KOReader annotations** (highlights, notes, bookmarks)
- **Automatic background sync** when a network connection is detected
- **Smart merging:** resolves annotation conflicts by update time
- **Failsafe protection** prevents accidental remote data loss when setting up a fresh device
- **Trash Bin & Restoration:** easily view and undelete accidentally removed notes
- **Manual sync & remote backup** for peace of mind
- **Supports multiple annotation formats & metadata** (EPUB, PDF, and more)
- **Configurable sync files:** use hashes or filenames for cloud storage
- **Lightweight, minimal setup—just enable and configure!**

## 📦 Installation

1. Copy this folder to your KOReader `plugins` directory (make sure it is named `AnnotationSync.koplugin`)
2. Restart KOReader.
3. Enable AnnotationSync from the plugins menu.

## 🛠 Usage

### ⚙️ Initial Setup

Before using AnnotationSync, you must configure your cloud storage:
- Tools -> Annotation Sync -> Settings -> Cloud settings
- Add a cloud storage service, if necessary:
  - Add service -> +
  - Supported providers: Dropbox, FTP, WebDAV
- Select the desired cloud storage service from the list
- Restart KOReader as indicated after selection

**Cloud Storage Filenames:**
By default, sync files are named after a hash of the document content. If you prefer to use the actual filename (e.g., if you modify metadata with Calibre):
- Tools -> Annotation Sync -> Settings -> Use filename instead of hash

### 🔄 Automatic Syncing

AnnotationSync can automatically mass-upload any pending changes whenever your device connects to the internet:
- Tools -> Annotation Sync -> Settings -> Automatically Sync All when network becomes available

### 💾 Manual Syncing

You can sync your annotations at any time:
- **Manual Sync**: Sync only the current document.
  - Tools -> Annotation Sync -> Manual Sync
- **Sync All**: Mass-upload all pending changes from your offline reading sessions.
  - Tools -> Annotation Sync -> Sync All
- **Shortcuts**: You can also bind "Annotation Sync: Manual Sync" to a gesture or add it to a profile action list.

### 🗑 Managing Deletions (Trash Bin)

AnnotationSync keeps track of deleted annotations so you can recover them:
- Tools -> Annotation Sync -> Show Deleted
- Tap on any deleted item to restore it, or use "Restore All" to recover everything.
- Restored items will be re-synced to the cloud on the next sync.

## 📦 DropBox setup

Setting up Dropbox on Koreader can be a little bit difficult. 
[This excellent post on mobileread forum](https://www.mobileread.com/forums/showthread.php?t=353670) explains the procedure in detail.

## 🧪 Running Tests

The project includes a comprehensive integration test suite. To run them, you need a KOReader development environment (`kodev`).

### Automated script

```bash
./run_tests.sh <path_to_koreader>
```

### Manual run

1. **Setup**: Symbolically link test files into the KOReader core `spec/unit` directory:
   ```bash
   cd /path/to/koreader
   ln -s ../../plugins/AnnotationSync.koplugin/spec/unit/*.lua spec/unit/
   ```

2. **Execute Tests**: Run all tests or a specific suite using `./kodev`:
   ```bash
   # Run all AnnotationSync integration tests
   ./kodev test front sync_integration sync_pdf_integration sync_bookmark sync_mixed_offline sync_protection sync_trash error_handling
   ```

3. **Test Suites**:
   - `sync_integration`: Core EPUB merging and conflict resolution.
   - `sync_pdf_integration`: PDF-specific coordinate merging and drift tolerance.
   - `sync_bookmark`: Bookmark (page-based) tracking and synchronization.
   - `sync_mixed_offline`: "Sync All" behavior with mixed document types and offline handling.
   - `sync_protection`: Safety checks to prevent accidental remote data loss.
   - `sync_trash`: Verification of deleted item retrieval and restoration logic.
   - `error_handling`: Network flakiness and malformed data scenarios.

## 🤝 Contributing

Pull requests, feature suggestions, and bug reports are very welcome! Open an issue or submit a PR.

## 📄 Known Issues

- ~~Can't synchronize pdf highlights due to their different data structure.~~ Fixed
- ~~Binding the "Annotation Sync: Manual Sync" action to a profile with "Auto-execute -> on book closing" will cause KOReader to crash.~~ Fixed

---

**AnnotationSync.koplugin**: Your reading notes, highlights, and bookmarks—always with you, always safe.
