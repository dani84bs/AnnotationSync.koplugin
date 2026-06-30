# AnnotationSync.koplugin

> **Sync your KOReader annotations everywhere!**
>
> Never lose a highlight, note, bookmark, or reading progress again—AnnotationSync keeps your reading life in sync across all your devices.

## 📋 Table of Contents

- [Features](#-features)
- [KOReader Version Requirements](#️-koreader-version-requirements)
- [Installation](#-installation)
- [Cloud Storage Setup](#️-cloud-storage-setup)
- [Usage & Configuration](#-usage--configuration)
  - [Manual & Bulk Annotation Sync](#-manual--bulk-annotation-sync)
  - [Reading Progress Sync](#-reading-progress-sync)
  - [Settings Synchronization](#️-settings-synchronization)
  - [Managing Deletions (Trash Bin)](#-managing-deletions-trash-bin)
  - [Pending Documents Queue](#-pending-documents-queue)
  - [Gesture & Profile Shortcuts](#️-gesture--profile-shortcuts)
- [Dropbox Setup](#️-dropbox-setup)
- [Koofr (WebDAV) Setup](#️-koofr-webdav-setup)
- [Running Tests](#-running-tests)
- [Contributing](#-contributing)

---

## 🚀 Features

- **Cloud sync for KOReader annotations** (highlights, notes, bookmarks) for both EPUB and PDF documents
- **Multi-device Reading Progress Sync:** Keep your active page, percentage, and precise position synchronized between all your reading devices.
- **Settings Synchronization:** Synchronize your KOReader configuration settings (e.g., gesture configurations, page overlap styles, custom hotkeys) across all your devices selectively via your cloud storage.
- **Smart page alignment for reflowable documents (EPUB):** Sync progress via the page's last word rather than just page numbers to maintain reading consistency across different screen sizes, font settings, margins, or orientations.
- **Customizable Device Name:** Assign friendly custom names to your devices (e.g., "Bedside Kobo", "Phone") to easily identify them in sync menus.
- **Automatic background sync:** Quietly updates your progress in the background as you turn pages, preventing intrusive popup messages.
- **Core Cloud Storage Integration:** Integrates with KOReader's cloud storage plugin (Dropbox, FTP, WebDAV, etc.), supporting both the new Cloud storage+ plugin and the legacy SyncService.
- **Smart merging:** Resolves conflicts by comparing update timestamps to preserve your latest annotations.
- **Failsafe protection:** Prevents accidental remote data loss when setting up a fresh device.
- **Trash Bin & Restoration:** Easily view and undelete accidentally removed notes/highlights.
- **Pending Documents Queue:** View and manage documents awaiting sync, with options to sync individually or remove from the queue.
- **Configurable sync files:** Use hashes or actual filenames for sync storage.
- **Localization:** Available in English, Italian (it_IT), and Hungarian (hu).

## ⚠️ KOReader Version Requirements

> [!WARNING]
> **Reading Progress Sync** requires a **development/nightly version** of KOReader that includes the **Cloud storage+** plugin. On stable releases without this plugin, all progress sync options will be greyed out in the menu and a **"Why are some options greyed out?"** item will explain this in-app.
>
> Core annotation sync works on both stable and development versions.

## 📦 Installation

1. Download or clone this repository.
2. Copy the folder to your KOReader `plugins` directory (it must be named exactly `AnnotationSync.koplugin`).
3. Restart KOReader.
4. Enable AnnotationSync from the plugins menu.

## ☁️ Cloud Storage Setup

AnnotationSync supports two cloud integration methods, depending on your version of KOReader.

### Cloud storage+ plugin (dev/nightly KOReader — recommended)

Newer KOReader development builds include a **Cloud storage+** plugin that manages all your cloud accounts in one place. AnnotationSync integrates with it automatically.

**Step 1 — Configure your provider in Cloud storage+:**
1. In KOReader, open **Tools → Cloud storage+**.
2. Add your cloud account (Dropbox, WebDAV, FTP, etc.) if you haven't already. See [Dropbox Setup](#️-dropbox-setup) or [Koofr (WebDAV) Setup](#️-koofr-webdav-setup) for provider-specific instructions.

**Step 2 — Connect AnnotationSync:**
1. Go to **Tools → Annotation Sync → Settings → Cloud settings**.
2. Your configured cloud accounts are listed. Select the one to use for annotation sync.
3. The selected destination is now shown in the menu under **Current cloud**.

> *By default, sync files are named after an MD5 hash of the document path. To use actual filenames instead (useful if you organize files with Calibre):*
> **Tools → Annotation Sync → Settings → Use filename instead of hash**

### Legacy SyncService (stable KOReader)

On stable KOReader releases without the Cloud storage+ plugin, AnnotationSync uses KOReader's built-in SyncService.

1. Go to **Tools → Annotation Sync → Settings → Cloud settings**.
2. A configuration dialog opens directly. Select your provider type and enter your server details (URL, username, password).
3. Tap **Confirm** to save. Restart KOReader if prompted.

> [!NOTE]
> Reading Progress Sync and Cloud storage+ integration are unavailable on stable KOReader. The "Why are some options greyed out?" menu item provides an in-app explanation.

## 🛠 Usage & Configuration

### 💾 Manual & Bulk Annotation Sync

- **Manual Sync** — Immediately sync the current document's annotations and bookmarks (bidirectional merge). Runs regardless of whether the document has local pending changes.
  - **Tools → Annotation Sync → Manual Sync**

- **Sync All** — Mass-sync all documents that have pending local changes.
  - **Tools → Annotation Sync → Sync All**

- **Automatic Syncing** — Automatically run Sync All as soon as a network connection becomes available.
  - **Tools → Annotation Sync → Settings → Automatically Sync All when network becomes available**

> [!IMPORTANT]
> **Understanding Sync All vs. Manual Sync**
>
> **Sync All** only processes documents that AnnotationSync has locally marked as *changed* ("dirty") on *this device* — i.e., books you annotated here since the last sync. It will **not** pull down changes that another device pushed to the cloud, because those documents are not in your local pending queue.
>
> **Manual Sync** always performs a full bidirectional merge for the active document, regardless of local pending state. Use it when you want to fetch annotations that another device pushed for a book you haven't annotated locally.
>
> **Rule of thumb:** *Sync All = push your own offline work. Manual Sync = also pull what others pushed.*

### 🔄 Reading Progress Sync

*(Requires dev/nightly KOReader with the Cloud storage+ plugin)*

1. Go to **Tools → Annotation Sync → Settings**.
2. Enable **Enable Reading Progress Sync**.
3. Customize your progress sync preferences:
   - **Device name:** Give your device a friendly name under **Device name: [Name]** (e.g. `Bedside Kobo`, `Phone`). Defaults to the hardware model name if left blank.
   - **Sync using last word of page:** Recommended for reflowable formats like EPUB. Keeps tracking consistent even if font sizes or margins differ between devices.
   - **Sync every # pages:** Customize how frequently progress syncs in the background (default: 1 page turn).
4. To jump to the progress of another device:
   - Go to **Tools → Annotation Sync → Jump to device progress**.
   - Select a device from the menu (sorted by progress percentage descending, with alphabetical tie-breaking by device name) to jump directly to its reading position.

### ⚙️ Settings Synchronization

Keep your KOReader settings (e.g., gestures, hotkeys, page overlap style) synchronized across devices.

#### 1. Selecting Settings to Sync
1. Go to **Tools → Annotation Sync → Settings → Show changed settings**.
2. This displays a hierarchical list of settings that differ from their default/vanilla configuration, categorized by domains (e.g., `[reader]`, `[defaults]`, `[settings/hotkeys]`).
3. Dictionary settings open submenus, and list arrays are compared as single entities.
4. Tap items to toggle their sync status. A checkmark `[✓]` indicates it will be synchronized:
   ```text
   [✓] [reader] page_overlap_style: default -> none
   [ ] [settings/hotkeys] hotkey_map >
   ```
5. Use **Select All** or **Clear Selection** at any menu level to batch-configure. Your selections are automatically saved.

#### 2. Pushing Settings to the Cloud
1. Go to **Tools → Annotation Sync → Push settings to cloud**.
2. The selected settings are uploaded, keyed by your device name.

#### 3. Pulling Settings from the Cloud
1. Go to **Tools → Annotation Sync → Pull settings from cloud**.
2. Select the device whose settings you want to import (timestamps are shown).
3. The plugin displays the differences between that device's settings and your local configuration.
4. Select which settings to import and tap **Import Selected Settings**. Changes are applied immediately.

> [!IMPORTANT]
> **Exclusions & Failsafes**
> The following settings are strictly excluded from synchronization to prevent credential leaks, sync loops, and device conflicts:
> - **Private credentials and server configurations** (e.g., `cloud_server_object`, FTP/WebDAV passwords)
> - **Device-specific identifiers and paths** (e.g., `device_id`, `device_name`, `lastfile`, `home_dir`, font maps, cover caches)
> - **Core plugin settings** (e.g., `annotation_sync_plugin` and `AnnotationSync` preferences)
> - **Database and statistics logs** (e.g., battery stats, terminal configs, book statistics)

> [!WARNING]
> **Security Warning**
> Synced settings are stored in cleartext (unencrypted JSON) on your cloud storage under `settings_sync.json`. Avoid syncing sensitive or private configuration values.

### 🗑 Managing Deletions (Trash Bin)

AnnotationSync tracks deleted annotations so you can recover them:
- **Tools → Annotation Sync → Show Deleted**
- Tap on any deleted item to restore it, or use **Restore All** to recover everything.
- Restored items will be re-synced to the cloud on the next sync.

### 📋 Pending Documents Queue

AnnotationSync tracks all documents with local annotation changes pending sync:
- **Tools → Annotation Sync → Show pending/unsynced documents**
- Shows every document in the sync queue.
- You can sync an individual document directly from this list, or remove it from the queue without syncing.
- Useful for diagnosing why Sync All is or isn't picking up a particular document.

### ⌨️ Gesture & Profile Shortcuts

All AnnotationSync actions can be bound to gestures or added to KOReader profile action lists via **Settings → Taps and Gestures** or the **Profiles** plugin:

| Action title | What it does |
|---|---|
| AnnotationSync: Manual Sync | Sync the active document's annotations |
| AnnotationSync: Sync All | Sync all locally-changed documents |
| AnnotationSync: Push reading progress | Push the current page position to the cloud |
| AnnotationSync: Jump to device progress | Open the device progress selector |
| AnnotationSync: Push settings to cloud | Upload selected settings |
| AnnotationSync: Pull settings from cloud | Browse and import settings from another device |

## ☁️ Dropbox Setup

Setting up Dropbox on KOReader can be a little bit difficult.
[This excellent post on the MobileRead forum](https://www.mobileread.com/forums/showthread.php?t=353670) explains the procedure in detail.

## ☁️ Koofr (WebDAV) Setup

Koofr is a cloud storage provider that supports WebDAV. Connecting KOReader to Koofr via WebDAV requires a dedicated application password instead of your primary Koofr password.

### 1. Generate an Application Password on Koofr
1. Log in to the [Koofr Web App](https://app.koofr.net/).
2. Open your account menu and go to **Preferences**.
3. Select **Password** from the menu on the left.
4. Go to the **Generate new password** section, enter a name (e.g., `KOReader`), and click **Generate**.
5. Copy the generated password. *Note: You will not be able to see it again after leaving the page.*

### 2. Configure WebDAV in KOReader

**With Cloud storage+ (dev/nightly KOReader):**
1. Go to **Tools → Cloud storage+** and add a new WebDAV server.
2. Fill in the connection details (see below) and save.
3. Then go to **Tools → Annotation Sync → Settings → Cloud settings** and select your newly added Koofr server.

**With the legacy SyncService (stable KOReader):**
1. Go to **Tools → Annotation Sync → Settings → Cloud settings**.
2. Choose **Add WebDAV server** (or select your existing WebDAV entry to update it).
3. Fill in the connection details below and save.

**Connection details:**
- **Name**: `Koofr` (or any name of your choice)
- **WebDAV address**: `https://app.koofr.net/dav/Koofr`
- **Username**: Your Koofr account email address
- **Password**: The application-specific password generated in Step 1 (do **not** use your primary Koofr login password)
- **Start folder**: `/koreader` or `/AnnotationSync` — recommended to keep sync files in a dedicated directory. If you use a custom subdirectory, make sure it exists in Koofr before syncing.

## 🧪 Running Tests

The project includes a comprehensive integration test suite. To run it, you need a KOReader development environment (`kodev`).

### Automated script

```bash
./run_tests.sh <path_to_koreader>
```

The script compiles translations, automatically discovers all test suites in `spec/unit/`, links them into the KOReader `spec/unit` directory, and runs them via `./kodev test`. Symlinks are cleaned up on exit.

### Manual run

1. **Setup**: Symbolically link test files into the KOReader core `spec/unit` directory:
   ```bash
   cd /path/to/koreader
   ln -s ../../plugins/AnnotationSync.koplugin/spec/unit/*.lua spec/unit/
   ```

2. **Execute Tests**: Run all tests or a specific suite:
   ```bash
   ./kodev test front <test_name>
   ```
   Replace `<test_name>` with any `*_spec.lua` filename in `spec/unit/`, without the `_spec.lua` suffix (e.g. `sync_integration`, `progress_sync_integration`, `settings_persistence`).

## 🤝 Contributing

Pull requests, feature suggestions, and bug reports are very welcome! Open an issue or submit a PR.

---

**AnnotationSync.koplugin**: Your reading notes, highlights, and bookmarks—always with you, always safe.
