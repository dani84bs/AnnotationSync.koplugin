# AnnotationSync.koplugin

> **Sync your KOReader annotations everywhere!**
>
> Never lose a highlight or note again—AnnotationSync keeps your reading life in sync across all your devices.

## 🚀 Features
- **Cloud sync for KOReader annotations** (highlights, notes, bookmarks)
- **Manual sync & remote backup** for peace of mind
- **Easy access from KOReader's main menu**
- **Configurable cloud server settings**
- **Smart merging:** resolves annotation conflicts by update time
- **Detects and marks deleted annotations**
- **Supports multiple annotation formats & metadata**
- **Lightweight, minimal setup—just enable and configure!**

## 📦 Installation
1. Copy this folder to your KOReader `plugins` directory (make sure it is named `AnnotationSync.koplugin`)
2. Restart KOReader.
3. Enable AnnotationSync from the plugins menu.

## 🛠 Usage
- Open KOReader and activate AnnotationSync from the plugins menu:
  - Tools -> More tools -> Plugin management
- Choose the cloud storage source in Annotation Sync settings:
  - Tools -> Annotation Sync -> Settings
  - Add a cloud storage service, if necessary:
    - Add service -> +
    - Supported providers: Dropbox, FTP, WebDAV
  - Select the desired cloud storage service from the list
  - Restart KOReader as indicated after selection

- Sync your annotations at any time:
  - Use the menu: Tools -> Annotation Sync -> Manual Sync
  - Or bind the "Annotation Sync: Manual Sync" action to a gesture or keyboard shortcut
  - Or add the "Annotation Sync: Manual Sync" action to a profile action list

### 📦 DropBox setup
Setting up Dropbox on Koreader can be a little bit difficult. 
[This excellent post on mobileread forum](https://www.mobileread.com/forums/showthread.php?t=353670) explains the procedure in detail.

## Details
AnnotationSync stores its files directly in the selected cloud storage
directory, so you may want to create a new directory dedicated to AnnotationSync.
The sync files are named according to a hash of the document being synced, so it
will look something like this:

```
.
..
330209864aecdf8cc63a16022f6a30f8.json
dda324e17e50f6c8c4c481ee4fcb1aa4.json
```

There is currently no other identifying information about the original document name stored in either the
filesystem or the contents of the files.

## 🤝 Contributing
Pull requests, feature suggestions, and bug reports are very welcome! Open an issue or submit a PR.

## 📄 Known Issues
- Binding the "Annotation Sync: Manual Sync" action to a profile with "Auto-execute -> on book closing" will cause KOReader to crash.
- ~~At the moment intersections between highlights spanning different
epub blocks may not be detected.~~ Fixed in [4ae7868](https://github.com/dani84bs/AnnotationSync.koplugin/commit/4ae7868057991f57ab2d7ff865d1201ebfd5e53e)

---

**AnnotationSync.koplugin**: Your reading notes, highlights, and bookmarks—always with you, always safe.

