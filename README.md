# AnnotationSync.koplugin

> **Sync your KOReader annotations everywhere!**
>
> Never lose a highlight, note, bookmark, or reading progress again—AnnotationSync keeps your reading life in sync across all your devices.

## 🚀 Features

- **Cloud sync for KOReader annotations** (highlights, notes, bookmarks)
- **Multi-device Reading Progress Sync:** Keep your active page, percentage, and precise position synchronized between all your reading devices.
- **Smart page alignment for reflowable documents (EPUB):** Sync progress via the page's last word rather than just page numbers to maintain reading consistency across different screen sizes, font settings, margins, or orientations.
- **Automatic background sync:** Quietly updates your progress in the background (using a dedicated background helper) as you turn pages, preventing intrusive popup messages.
- **Core Cloud Storage Integration:** Integrates seamlessly with KOReader's native cloud storage plugin (supporting Dropbox, FTP, WebDAV, etc.).
- **Backward Compatibility:** Safe fallback mode for older KOReader versions, disabling unsupported settings gracefully without breaking core annotation sync.
- **Smart merging:** Resolves conflicts by comparing update timestamps to preserve your latest annotations.
- **Failsafe protection:** Prevents accidental remote data loss when setting up a fresh device.
- **Trash Bin & Restoration:** Easily view and undelete accidentally removed notes/highlights.
- **Configurable sync files:** Use hashes or actual filenames for sync storage.

## ⚠️ Warning: KOReader Development Version Required

> [!WARNING]
> **Reading Progress Sync** and core **Cloud Storage plugin integration** require a **development/nightly version** of KOReader. If you are on a stable release of KOReader, these features will be disabled (greyed out in the menu) and a fallback explanation option will be displayed.

## 📦 Installation

1. Download or clone this repository.
2. Copy this folder to your KOReader `plugins` directory (ensure it is named exactly `AnnotationSync.koplugin`).
3. Restart KOReader.
4. Enable AnnotationSync from the plugins menu.

## 🛠 Usage & Configuration

### ⚙️ Cloud Storage Setup

AnnotationSync integrates directly with KOReader's native Cloud Storage plugin:
1. Ensure your cloud storage provider is configured in KOReader.
2. Go to **Tools** -> **Annotation Sync** -> **Settings** -> **Cloud settings**.
3. Select your desired cloud storage service.
4. Restart KOReader as indicated.

*By default, sync files are named after a hash of the document content. To use actual filenames instead (useful if you organize files with Calibre):*
- **Tools** -> **Annotation Sync** -> **Settings** -> **Use filename instead of hash**

### 🔄 Reading Progress Sync

To configure multi-device reading progress synchronization:
1. Go to **Tools** -> **Annotation Sync** -> **Settings**.
2. Enable **Enable Reading Progress Sync**.
3. Customize your progress sync preferences:
   - **Sync using last word of page:** Recommended for reflowable formats like EPUB. Keeps tracking consistent even if font sizes or margins differ between devices.
   - **Sync every # pages:** Customize how frequently progress syncs in the background (default: 1 page turn).
4. To jump to the progress of another device:
   - Go to **Tools** -> **Annotation Sync** -> **Jump to device progress**.
   - Select a device from the menu (sorted by latest timestamp) to jump directly to its reading position.

### 💾 Manual & Bulk Annotation Sync

- **Manual Sync:** Sync only the current document's annotations and bookmarks.
  - **Tools** -> **Annotation Sync** -> **Manual Sync**
- **Sync All:** Mass-upload/download pending changes from all your offline reading sessions.
  - **Tools** -> **Annotation Sync** -> **Sync All**
- **Automatic Syncing:** Automatically mass-sync all modified documents as soon as a network connection becomes available.
  - **Tools** -> **Annotation Sync** -> **Settings** -> **Automatically Sync All when network becomes available**
- **Shortcuts:** You can bind "Annotation Sync: Manual Sync" or "Annotation Sync: Jump to device progress" to any gesture or add them to a profile action list in KOReader.

### 🗑 Managing Deletions (Trash Bin)

AnnotationSync keeps track of deleted annotations so you can recover them:
- **Tools** -> **Annotation Sync** -> **Show Deleted**
- Tap on any deleted item to restore it, or use **Restore All** to recover everything.
- Restored items will be re-synced to the cloud on the next sync.

## 📦 Dropbox Setup

Setting up Dropbox on KOReader can be a little bit difficult. 
[This excellent post on the MobileRead forum](https://www.mobileread.com/forums/showthread.php?t=353670) explains the procedure in detail.

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
   ./kodev test front sync_integration sync_pdf_integration sync_bookmark sync_mixed_offline sync_protection sync_trash error_handling progress_sync_integration settings_persistence background_sync backward_compatibility
   ```

## 🤝 Contributing

Pull requests, feature suggestions, and bug reports are very welcome! Open an issue or submit a PR.

---

**AnnotationSync.koplugin**: Your reading notes, highlights, and bookmarks—always with you, always safe.
