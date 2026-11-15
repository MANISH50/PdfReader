# Third-party notices

PdfReader is released under the [MIT License](LICENSE).
It uses the open-source software listed below. Thank you to all their authors.

This list shows the **main** dependencies. The app has a **Licenses** page (in **Settings**) that shows the full license
text of **every** package included in the app, including packages pulled in by other packages.

In the app: **Settings** ▸ **Licenses**.

## Runtime dependencies

| Component | Version | License | Use in PdfReader |
|---|---|---|---|
| [Flutter](https://github.com/flutter/flutter) and the Dart SDK | 3.50.0 | BSD-3-Clause | App framework |
| [material_ui](https://pub.dev/packages/material_ui) | 1.11.0 | BSD-3-Clause | Material widgets |
| [cupertino_ui](https://pub.dev/packages/cupertino_ui) | 1.1.6 | BSD-3-Clause | iOS-style widgets |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons) | 1.0.8 | MIT | iOS-style icons |
| [pdfrx](https://pub.dev/packages/pdfrx) | 2.12.1 | MIT | PDF viewer, text, search, page editing |
| [pdfrx_engine](https://pub.dev/packages/pdfrx_engine) | 0.9.2 | MIT | PDF engine layer (used by pdfrx) |
| [pdfium_flutter](https://pub.dev/packages/pdfium_flutter) | 0.4.2 | MIT | PDFium bindings (used by pdfrx) |
| [PDFium](https://pdfium.googlesource.com/pdfium/) (binaries from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries), chromium/8125, no V8/XFA) | 8125 | BSD-3-Clause and Apache-2.0 | PDF rendering engine |
| Libraries bundled inside PDFium (FreeType, libjpeg-turbo, zlib, libpng, OpenJPEG, lcms2, and others) | — | FreeType License (FTL), IJG / BSD-3-Clause, zlib, libpng, BSD-2-Clause, MIT | Fonts and image decoding |
| [pdf](https://pub.dev/packages/pdf) | 3.13.1 | Apache-2.0 | Creating new PDFs (images to PDF, DOCX to PDF, flattened export) |
| [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) | 3.5.0 | MIT | State management |
| [go_router](https://pub.dev/packages/go_router) | 18.1.4 | BSD-3-Clause | Navigation |
| [file_picker](https://pub.dev/packages/file_picker) | 13.3.3 | MIT | System file picker |
| [share_plus](https://pub.dev/packages/share_plus) | 13.3.1 | BSD-3-Clause | System share sheet |
| [receive_sharing_intent](https://pub.dev/packages/receive_sharing_intent) | 1.9.0 | Apache-2.0 | Receiving files from **Open with** and **Share** |
| [archive](https://pub.dev/packages/archive) | 4.7.1 | MIT | Reading and writing ZIP (DOCX files) |
| [image](https://pub.dev/packages/image) | 4.13.1 | MIT | Image conversion |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | BSD-3-Clause | Finding the app's private folders |
| [path](https://pub.dev/packages/path) | 1.9.x | BSD-3-Clause | File path helpers |
| [crypto](https://pub.dev/packages/crypto) | 3.0.x | BSD-3-Clause | File hashes |

Also: `url_launcher` (BSD-3), `wakelock_plus` (BSD-3), `pdfium_dart` (MIT), `ffi` (BSD-3). Full list with versions: in-app Licenses page and `pubspec.lock`.

## Build-time tools (not shipped in the app)

| Component | Version | License |
|---|---|---|
| [flutter_lints](https://pub.dev/packages/flutter_lints) | 6.x | BSD-3-Clause |
| [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons) | 0.14.4 | MIT |
| [flutter_native_splash](https://pub.dev/packages/flutter_native_splash) | 2.4.8 | MIT |

## What we do not use

To keep PdfReader fully open source, we do **not** use: MuPDF (AGPL), Poppler (GPL), Syncfusion, Nutrient/PSPDFKit or Apryse
(commercial), or Google ML Kit (closed binaries).

## Full license texts

- The full text of each license is in the app's **Licenses** page.
- You can also find it in each package's `LICENSE` file on pub.dev or GitHub.
- PDFium's license and the licenses of its bundled libraries are in the `LICENSE` file of the
  [pdfium-binaries release](https://github.com/bblanchon/pdfium-binaries/releases).
