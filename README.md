# PdfReader

PdfReader is a free PDF reader and editor for **Android** and **iPhone**.
It also runs on Windows, macOS and Linux.

It works **fully offline**. It has no ads, no accounts and no tracking.
Your files never leave your device.

PdfReader is open source under the [MIT License](LICENSE).
It uses only free and open-source libraries.

Current version: **1.0.0**

---

## Download

- **Android:** download the APK file from the
  [GitHub Releases page](https://github.com/MANISH50/PdfReader/releases).
  Download: [https://github.com/MANISH50/PdfReader/releases/latest](https://github.com/MANISH50/PdfReader/releases/latest)
- **iPhone:** there is no App Store version yet. See [INSTALL.md](INSTALL.md) for your options.

Step-by-step help for both phones is in **[INSTALL.md](INSTALL.md)**.

---

## Screenshots

<!-- Screenshots will be added after the first device test run. -->

| Library | Reading | Dark mode |
|---|---|---|
| ![Library](docs/images/screenshot-library.png) | ![Reading](docs/images/screenshot-reader.png) | ![Dark mode](docs/images/screenshot-dark.png) |

| Annotate | Organize pages | Export |
|---|---|---|
| ![Annotate](docs/images/screenshot-annotate.png) | ![Organize pages](docs/images/screenshot-organize.png) | ![Export](docs/images/screenshot-export.png) |

---

## Features



### Reading
- Smooth scrolling and sharp pages at any zoom.
- Pinch to zoom. Double-tap to zoom in.
- Tap the page to hide or show the toolbars.
- Page number, a fast scroll bar and **Go to page**.
- Table of contents, page thumbnails and bookmarks.
- Search inside the document. Select and copy text.
- Links inside the document. Back and forward after you follow a link.
- Opens password-protected PDFs.
- Also opens Word (.docx), Markdown (.md) and plain-text files (.txt, logs, JSON, code) for reading — offline, with search, text size and page colours.
- Opens Excel workbooks (.xlsx) and CSV/TSV files as a scrollable table: sheet tabs, sticky header row, row numbers, search across sheets, tap a cell to copy it. Cell values only (formulas show their last saved result; charts and pictures are not shown). Old .xls files are not supported.
- Light, dark, sepia and inverted page colours.
- Remembers your last page and zoom for each file.

### Editing
- Highlight, underline and strike out text.
- Draw with your finger or a stylus. Add text notes and text boxes.
- Add a signature. Cover parts of a page with a white box.
- Undo and redo.
- Organize pages: move, rotate, delete, insert and extract pages.
- Merge several PDFs. Split a PDF by page range.
- Make a PDF from photos or images.

### Saving and export
- **Save as a copy** is the default. Your original file is not changed unless you choose **Replace original**.
- Export to PDF, PNG, JPG, plain text and DOCX (Word).
- Export your highlights and notes as text.

### Works with your phone
- **Android:** set PdfReader as your default PDF app, or pick it from **Open with**.
- **iPhone:** open PDFs from the **Files** app with **Share** or **Open in**.
- Share any PDF from another app straight into PdfReader.
- Share your edited copy to any app with the system share sheet.

---

## Privacy promise

- **No internet.** The Android app does not ask for the internet permission at all. The iPhone app makes no network calls.
- **No ads, no analytics, no tracking, no crash reporting.**
- **No accounts.** You never sign in.
- **Everything happens on your device.** Conversions (for example PDF to DOCX or images to PDF) run on the phone.
- Your recent files, notes and settings are stored only inside the app's private storage.

Details are in [SECURITY.md](SECURITY.md).

---

## Honest limitations

We want you to know what PdfReader cannot do (yet):

- **DOCX export keeps text and basic layout only.** Complex layouts, tables, columns and exact fonts may look different.
- **Annotations are flattened into saved copies.** Highlights, drawings and notes become part of the page in the exported file.
  Other apps can see them but cannot edit them as separate notes. Inside PdfReader you can still edit them.
- **iPhone has no system-wide "default PDF app" setting.** You open PDFs in PdfReader from **Share** or **Open in** each time.
- **Form filling:** Text fields, checkboxes, radio buttons, combo boxes and list boxes (AcroForm) can be filled. Digital-signature fields and form scripts are not supported. XFA forms are not supported.
- **You cannot change the existing text** of a PDF. You can cover it with a white box and add new text on top.
- **No OCR** (text recognition for scanned pages) in this version.

---

## Build from source

### What you need
- **Flutter 3.50.0** (stable). Check with `flutter --version`.
- For Android: Android Studio or the Android SDK.
- For iPhone: **a Mac with Xcode**. You cannot build the iPhone app on Windows or Linux.

### Run in debug mode

```sh
git clone https://github.com/MANISH50/PdfReader.git
cd PdfReader
flutter pub get
flutter run
```

### Build a release for Android

```sh
# APK (to install directly on a phone)
flutter build apk --release --obfuscate --split-debug-info=build/symbols

# App Bundle (for app stores)
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

The files are in `build/app/outputs/flutter-apk/` and `build/app/outputs/bundle/release/`.
Keep the `build/symbols` folder. You need it to read crash stack traces.

### Signing (Android)

Release builds need your own signing key. Use **one** of these two ways.

**Option 1: a `android/key.properties` file** (never commit this file):

```properties
storeFile=/full/path/to/your-keystore.jks
storePassword=your-store-password
keyAlias=your-key-alias
keyPassword=your-key-password
```

**Option 2: environment variables** (good for CI):

```sh
export PDFREADER_KEYSTORE_PATH=/full/path/to/your-keystore.jks
export PDFREADER_KEYSTORE_PASSWORD=your-store-password
export PDFREADER_KEY_ALIAS=your-key-alias
export PDFREADER_KEY_PASSWORD=your-key-password
```

To make a new keystore:

```sh
keytool -genkey -v -keystore pdfreader.jks -keyalg RSA -keysize 4096 -validity 10000 -alias pdfreader
```

> **Tip:** keep the keystore and passwords safe and backed up. If you lose them, users cannot update the app
> without uninstalling it first (and losing their data).

### Build for iPhone

1. Use a Mac with Xcode installed.
2. Run `flutter pub get`.
3. Open `ios/Runner.xcworkspace` in Xcode.
4. Choose your signing team. Then build and run.

Full steps, including a free Apple ID, are in [INSTALL.md](INSTALL.md#iphone).

### Run the tests

```sh
flutter analyze
flutter test
```

---

## Project structure

| Folder | What is inside |
|---|---|
| `lib/core/models/` | Data types: `DocumentRef`, `ReadingState`, `Annotation`, `ExportOptions`, `AppSettings` |
| `lib/core/commands/` | Undo and redo (`UndoStack`). Every edit is a `Command`. |
| `lib/core/storage/` | Private app folders, atomic JSON store, temp files (wiped on start) |
| `lib/core/security/` | `SecurityLimits` (size, page and time limits) and `LinkPolicy` (which links may open) |
| `lib/core/pdf/` | PDF engine contracts: open, edit pages, save |
| `lib/core/export/` | Export contract (`Exporter`) |
| `lib/core/providers.dart` | Wiring of all services (Riverpod) |
| `lib/platform/` | Open with, share and file picker services |
| `lib/features/` | Screens: library, viewer, editor (organize), export, settings, onboarding |
| `lib/ui/design_system/` | Colours, spacing, themes, page themes, adaptive widgets |
| `lib/app_router.dart` | Routes: `/`, `/onboarding`, `/settings`, `/viewer`, `/organize`, `/export` |
| `test/` | Unit and widget tests |
| `android/`, `ios/`, `macos/`, `windows/`, `linux/` | Platform projects |
| `docs/` | Extra documentation and images |

---

## Tech stack

| Part | Library | License |
|---|---|---|
| App framework | [Flutter](https://flutter.dev) | BSD-3-Clause |
| PDF viewing and page editing | [pdfrx](https://pub.dev/packages/pdfrx) (with `pdfrx_engine`, `pdfium_flutter`) | MIT |
| PDF engine | [PDFium](https://pdfium.googlesource.com/pdfium/) (build without JavaScript/V8 and XFA) | BSD-3-Clause / Apache-2.0 |
| Making new PDFs | [pdf](https://pub.dev/packages/pdf) | Apache-2.0 |
| State management | [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) | MIT |
| Navigation | [go_router](https://pub.dev/packages/go_router) | BSD-3-Clause |
| Pick files | [file_picker](https://pub.dev/packages/file_picker) | MIT |
| Share files | [share_plus](https://pub.dev/packages/share_plus) | BSD-3-Clause |
| Receive shared files | [receive_sharing_intent](https://pub.dev/packages/receive_sharing_intent) | Apache-2.0 |
| ZIP (for DOCX) | [archive](https://pub.dev/packages/archive) | MIT |
| Images | [image](https://pub.dev/packages/image) | MIT |
| App folders | [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause |

The full list is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
The app also has a **Licenses** page in **Settings** that lists every library.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem, see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
