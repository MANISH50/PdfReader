# PdfReader — Research Notes

*Compiled 2026-11-15. All package versions and licenses come from the pub.dev API
(`/api/packages/<name>` and `/api/packages/<name>/score`) on that date. Where a claim
rests on user reviews or forum posts, it is labeled as anecdotal.*

Goal: an open-source, **fully offline**, privacy-first PDF reader/editor for Android and
iPhone (desktop as a bonus), built with Flutter.

---

## 1. Competitive survey

| App | What users love | Common complaints |
|---|---|---|
| **Adobe Acrobat Reader** | The reference renderer with full fidelity. Forms, signatures, Liquid Mode reflow. | Heavy upselling: editing, export and the AI Assistant are paid add-ons. Sign-in prompts and Adobe cloud storage are pushed on users. Billing and trial-conversion complaints. Slow loading is the second-most-cited complaint on G2. Large install size. |
| **Xodo** (Apryse) | Historically free, fast, with good annotation tools. | Moved toward subscriptions. Usage allowances with forced waits (TechRadar). Some edit tools won't let you download the result without paying. Capterra mentions "3 daily scans" limits and disappearing tabs. |
| **PDF Expert** (Readdle, iOS/macOS) | Best-in-class polish on Apple devices: smooth scrolling, Apple Pencil support, a clean UI. | The 2019 move from one-time purchase to subscription (about $50/yr) still causes resentment. Some billing complaints. Apple-only. |
| **Foxit PDF Editor** | Fast, with many features and strong enterprise tools. | A Foxit account and a subscription are needed for advanced features. A separate AI subscription. Reports of charges continuing after cancellation (Trustpilot, Feb 2026). Users ask for a perpetual license. |
| **ReadEra** | Free, **no ads, no in-app purchases**, works offline, collects no data (App Store privacy label). Handles many formats (PDF/EPUB/DJVU/DOCX). Margin cropping and splitting scanned double-page spreads. | Almost no PDF editing or annotation writing. Some missing reading controls. iOS version less mature. |
| **Google (Drive / Files / built-in viewer)** | Free and already installed. Ink annotation (Android 6+). Form filling since 2019. No ads. | Tied to Drive, so files are pushed toward cloud upload. Weak on XFA forms and has no e-signature. Feature rollout varies by device. Few tools for organizing pages. |
| **Apple (Files Markup / Books / Preview / PDFKit)** | Free, integrated, with excellent Apple Pencil latency. | Long-running reports of **markup disappearing** or being lost through iCloud sync (Apple Community threads, 2018 to now). The 2026 PDFKit regression on iOS 27 (FB24866826) makes widget annotations disappear after saving. Markup **edits the original in place**, with no versioning. |

**Themes that recur across every app:**
1. Subscriptions and paywalls that grow over time ("they keep moving features behind the paywall").
2. Required sign-in or account creation, and cloud upload pushed on users, which raises privacy concerns.
3. Annotations lost, or originals overwritten without an undo or a copy.
4. Slow opening and scrolling on large or scanned PDFs, and bloated apps.
5. Ads (mostly in no-name Play Store readers).

This gives PdfReader its positioning: **no account, no network permission, no ads, no subscription,
never silently overwrites the original, and fast on 1,000-page files.**

Sources: [G2 Acrobat reviews](https://g2.com/products/adobe-acrobat/reviews?page=5),
[Adobe community thread](https://community.adobe.com/questions-15/i-have-a-standard-subscription-for-adobe-reader-with-adobe-itself-my-subscription-is-not-working-on-the-adobe-reader-mobile-app-i-tried-restoring-subscriptions-and-signing-into-my-account-again-however-nothing-happened-1629291),
[TechRadar Xodo review](https://www.techradar.com/pro/software-services/xodo-pdf-editor-review),
[Capterra Xodo](https://www.capterra.com/p/210439/Xodo/reviews/),
[PDF Expert subscription (The Sweet Setup)](https://thesweetsetup.com/pdf-expert-releases-version-7-switches-to-subscription-model/),
[MacRumors thread](https://forums.macrumors.com/threads/pdf-expert-7-subscription-alternatives.2190794),
[Foxit Trustpilot](https://uk.trustpilot.com/review/foxit.com?page=3),
[Foxit App Store](https://apps.apple.com/us/app/foxit-mobilepdf-pdf-reader/id507040546),
[ReadEra App Store](https://apps.apple.com/us/app/-/id1669188337),
[Drive annotate on Android](https://support.google.com/drive/answer/13207179),
[Drive PDF form filling](https://workspaceupdates.googleblog.com/2019/08/pdf-form-filling-drive.html),
[Apple Community: disappearing markups](https://discussions.apple.com/thread/7943423),
[Apple Dev Forums: PDFKit widget annotations disappear](https://developer.apple.com/forums/thread/847316),
[Zotero iOS annotation loss](https://forums.zotero.org/discussion/comment/505537/).

---

## 2. What makes reading feel premium

- **Instant first paint.** Show page 1 within about 300 ms. Render a low-resolution preview first, then sharpen. Open the file at the last-read page and zoom.
- **Sharp at any zoom.** Use *tiled* rendering: render only the visible region at device-pixel resolution, keep a low-res full page underneath, and never show a blurry stretched bitmap for long. pdfrx does partial rendering (`PdfPage.render` with x/y/width/height and render priorities).
- **120 Hz-smooth gestures.** Physics-based fling. Pinch-zoom anchored at the focal point. Double-tap to zoom smartly (fit the text column, then 2x, then fit page). Rubber-band edges. Smooth zoom-out to a grid of pages.
- **Tap to hide chrome.** A single tap toggles the toolbars. Immersive full-screen hides the system bars. A thin progress bar and a page pill ("12 / 340") fade in while scrolling.
- **A fast scrubber.** Drag a vertical scroll thumb with page-number and thumbnail previews. Long-press the page pill to jump to a page.
- **Layout modes.** Continuous vertical, horizontal paged (book-like), two-page spreads with a cover-page option, and RTL page order for manga and Arabic/Hebrew books.
- **Comfort.** Dark mode that recolors the page (inverted with hue preserved, or sepia; pdfrx `pageImageColorFilter`). Auto-crop margins. Keep the screen awake. Lock orientation.
- **Micro-polish.** Haptics on snap points. Page shadows and a paper look. Animated transitions between the library and the reader (a hero animation of the thumbnail). No layout jank when page sizes load progressively.
- **Respect memory.** Share an image cache budget, evict pages off screen, and release caches when the app goes to the background (pdfrx 2.11 added viewer suspension and a shared memory budget).

---

## 3. Convenience features most apps miss

- **Per-document memory:** last page, zoom, scroll mode, dark/crop settings, and a reading-position history with *back/forward* after following a link (like a browser).
- **Never overwrite by default:** "Save" writes `name (edited).pdf`, or a sidecar file, with an explicit "Replace original" option. Keep an undo history across sessions.
- **Recent files that survive moves:** keep persisted SAF URI permissions on Android and security-scoped bookmarks on iOS. Dedupe entries by content hash.
- **Search everything offline:** full-text search across the library (a local index in SQLite FTS5), plus in-document search with a hit list and context snippets.
- **Copy text cleanly:** de-hyphenate line breaks, join lines, and copy with a page citation.
- **Quick-jump to printed page labels** ("go to page xii").
- **A table of contents that's actually useful:** outline, thumbnails, bookmarks and annotations in one sidebar, searchable.
- **Split scanned two-page spreads** (as ReadEra does). Auto-crop white margins.
- **"Open with" or "Share to" works instantly** (no import or copy step). Optionally show "Open in PdfReader" in the share sheet.
- **One-handed mode:** volume keys turn pages, and an edge tap zone turns pages.
- **Export annotations** as Markdown or text with page numbers. Make highlights into a summary.
- **Images to PDF, offline:** camera or gallery to PDF, with crop and deskew.
- **Privacy guarantees users can verify:** no INTERNET permission on Android, and a published privacy label of "Data Not Collected".

---

## 4. Technology recommendation

### 4.1 Cross-platform framework

| Option | Verdict |
|---|---|
| **Flutter** | **Recommended.** It has its own renderer (Impeller), so gestures and animations look identical on iOS and Android and hit 120 Hz. FFI gives direct access to PDFium through pdfrx. One codebase covers Android, iOS, macOS, Windows and Linux. A mature package ecosystem. |
| React Native | Workable (react-native-pdf wraps PdfRenderer and PDFKit, or PDFium), but custom high-performance tiled rendering and gestures need native modules plus Reanimated and Skia. There is more bridge complexity for per-frame work. |
| Kotlin Multiplatform (+ Compose MP) | Strong for Android. Compose on iOS is newer, and you would need your own PDFium bindings on each platform. |
| .NET MAUI | Smaller mobile ecosystem. PDF libraries tend to be commercial (Syncfusion, Telerik). |

### 4.2 PDF engines

| Engine | License | Notes |
|---|---|---|
| **PDFium** (Google/Foxit) | BSD-3 / Apache-2 | Used by Chrome and Android. Fast and well fuzzed (OSS-Fuzz). Renders, extracts text, handles forms (FORM_*), annotations (FPDFAnnot_*), saves, and imports pages. **The best permissive choice.** |
| **MuPDF** | **AGPL-3.0** (or a commercial license from Artifex) | Excellent quality and reflow. AGPL is fine for an AGPL app, but it **forces the whole app to be AGPL** and complicates App Store distribution. **Avoid unless the project is AGPL.** |
| **pdf.js** (Mozilla) | Apache-2.0 | JavaScript. Only relevant for the web target (pdfrx's web backend uses PDFium WASM, and pdfx uses pdf.js). |
| **Poppler** | **GPL-2/3** | Desktop Linux-centric. **GPL would infect the app.** Avoid. |
| Apple PDFKit / Android PdfRenderer | OS-provided | Free, but behave differently per platform. PdfRenderer is render-only. PDFKit has the annotation-loss bugs noted above. |

### 4.3 Flutter PDF packages (verified)

**pdfrx 2.12.1 (MIT, published 2026-11-13)** is the primary choice. It is built on `pdfrx_engine`
0.9.2 and `pdfium_flutter` 0.4.2 (both MIT). It supports Android, iOS, macOS, Windows, Linux and Web (PDFium WASM).

- **PDFium build, with no V8 and no XFA (verified in source).** `pdfium_dart/hook/build.dart`
  downloads `pdfium-<platform>-<arch>.tgz` from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
  release `chromium/8125`. That is the *plain* variant. The V8/XFA variants are named
  `pdfium-v8-*.tgz`. Each archive is checked against pinned SHA-256 digests (`pdfium_archive_integrity.dart`).
  iOS and macOS use [espresso3389/pdfium-xcframework](https://github.com/espresso3389/pdfium-xcframework)
  (`v158.0.8125.0`), whose `build.sh` repackages the same plain `pdfium-ios-*.tgz` archives.
  **Result: no JavaScript engine and no XFA.** Document JavaScript cannot run.
- **Page editing:** `PdfDocument.pages` has a setter that accepts pages from *other* documents (merge,
  reorder, delete, insert). Pages can be rotated with `rotatedCW90()`, `rotatedTo()` and similar. Call `assemble()` after
  modifying, then `encodePdf({incremental, removeSecurity})` to get bytes. There are also `PdfDocument.createNew()` and
  `PdfDocument.createFromJpegData()` (JPEG only, so other image formats must be converted first).
- **Text:** `loadText()` returns plain text. `loadStructuredText()` returns text **with per-character bounding
  boxes** (it replaced `loadTextCharRects()`). Built-in text selection, `PdfTextSearcher` (with a start page and a
  custom `Pattern` since 2.12.0), and RTL/Hebrew fixes.
- **Links and outline:** `PdfPage.loadLinks()` returns URI and internal-destination links, with optional auto-detection of
  plain-text URLs. `PdfDocument.loadOutline()` returns bookmarks. `PdfLinkHandlerParams` handles link taps.
- **Passwords:** an async `passwordProvider` on all `open*` methods, `PdfPasswordException`,
  `isEncrypted`, and `permissions`.
- **Forms and annotations:** **rendering only.** `render(annotationRenderingMode: annotationAndForms)` draws
  existing annotations and form appearances. `PdfAnnotation` exposes *read-only metadata*. **There is no high-level
  API to create annotations or set form field values.** To write real `/Annot` objects or field values you
  have to call PDFium yourself through `useNativeDocumentHandle()` plus `pdfium_dart` FFI (`FPDFPage_CreateAnnot`,
  `FPDFAnnot_SetAttachmentPoints`, `FPDFAnnot_SetStringValue`, `FORM_*` and so on). That is feasible but hard, and
  native-only (not on the web).
- Other: progressive loading, `releaseCachedImages()`, render priorities, `pageImageColorFilter`
  (dark mode), and `PdfFontManager` for missing fonts.

**Others:**
- **pdfx 2.11.0 (MIT).** Uses the OS renderers (Android PdfRenderer, iOS/macOS CGPDF), PDFium on Windows, and pdf.js on the
  web. It mainly renders pages to images, with no text, link, form or editing APIs. Rendering differs between platforms. **Not recommended.**
- **syncfusion_flutter_pdfviewer / syncfusion_flutter_pdf 35.1.46.** pub.dev reports `license:unknown`. These are
  **commercial** (the Syncfusion license, with a free community license only for small companies). An open-source app cannot
  pass that license on to people who build it from source. **Red flag. Do not use.**
- **`pdf` 3.13.1 (Apache-2.0).** A pure-Dart PDF *writer*. Use it to generate *new* PDFs (images to PDF,
  text to PDF, DOCX-to-PDF output). It cannot parse or edit existing PDFs. Its sibling `printing` 5.15.1 (Apache-2)
  handles the print dialog.
- **Nutrient (formerly PSPDFKit) `nutrient_flutter` 6.0.0 and Apryse.** Paid, with closed binaries and license keys.
  (`pspdfkit_flutter` is discontinued.) **Red flag.** These are what you'd buy for full annotation, forms and DOCX support.

### 4.4 Supporting packages

- **file_picker / share_plus:** opening and sharing files. `share_plus` also covers "Save to Files" on iOS.
- **receive_sharing_intent 1.9.0 (Apache-2):** maintained (released 2026-06). The alternative is
  `flutter_sharing_intent` 2.0.4 (last release 2025-11). For a plain "Open with" (ACTION_VIEW, iOS
  document types), a small platform channel or `MethodChannel` is enough and avoids the package.
- **flutter_riverpod 3.5.0 / go_router 18.1.4:** state management and navigation.
- **drift 2.35.4 (MIT, on sqlite with FTS5) or sqflite 2.4.6 (BSD-2):** library, recents, bookmarks and the
  search index. Prefer drift for type-safe queries and migrations.
- **archive 4.7.1 (MIT):** unzip DOCX (OOXML) for basic DOCX-to-PDF or DOCX text import.
- **image 4.13.1 (MIT):** convert PNG/HEIC/WebP to JPEG for `createFromJpegData`, plus crop and rotate.
- **path_provider, flutter_launcher_icons, flutter_native_splash:** standard tooling.

### 4.5 OCR

- **Google ML Kit text recognition** (`google_mlkit_text_recognition` 1.0.3). The Dart plugin is MIT and the
  models run on-device and offline, **but the ML Kit SDK binaries are closed-source** and under Google's ML Kit terms.
  On Android the unbundled variant downloads its model through Play Services (bundle the model to stay offline).
  It **won't pass F-Droid rules**. Acceptable as an optional, clearly labeled plugin.
- **Tesseract** (engine: Apache-2.0). The Flutter wrappers are thin: `tesseract_ocr` 0.6.0 (BSD-3).
  `flutter_tesseract_ocr` is marked **discontinued** on pub.dev. You must bundle `.traineddata` files
  (several MB per language). It is the fully open option, but slower and less accurate on photos than ML Kit.

### 4.6 License table

| Package / component | Version (2026-11-15) | License | Verdict |
|---|---|---|---|
| pdfrx | 2.12.1 | MIT | **Use (core)** |
| pdfrx_engine | 0.9.2 | MIT | Use (transitive) |
| pdfium_flutter | 0.4.2 | MIT | Use (transitive) |
| PDFium binaries (bblanchon, chromium/8125, no V8/XFA) | 8125 | BSD-3 / Apache-2 (+ bundled FreeType, libjpeg-turbo, zlib, etc.) | Use. Include NOTICE files |
| pdf | 3.13.1 | Apache-2.0 | Use (generate new PDFs) |
| printing | 5.15.1 | Apache-2.0 | Optional |
| pdfx | 2.11.0 | MIT | Skip (weaker) |
| syncfusion_flutter_pdfviewer / _pdf | 35.1.46 | Commercial (Syncfusion) | **Do not use** |
| nutrient_flutter (PSPDFKit) / Apryse | 6.0.0 / n/a | Commercial | **Do not use** |
| MuPDF | n/a | AGPL-3.0 | **Do not use** (unless the app is AGPL) |
| Poppler | n/a | GPL | **Do not use** |
| file_picker | 13.3.3 | MIT | Use |
| share_plus | 13.3.1 | BSD-3-Clause | Use |
| receive_sharing_intent | 1.9.0 | Apache-2.0 | Use, or a custom channel |
| flutter_riverpod | 3.5.0 | MIT | Use |
| go_router | 18.1.4 | BSD-3-Clause | Use |
| drift | 2.35.4 | MIT | Use (preferred) |
| sqflite | 2.4.6 | BSD-2-Clause | Alternative |
| archive | 4.7.1 | MIT | Use |
| image | 4.13.1 | MIT | Use |
| path_provider | 2.1.6 | BSD-3-Clause | Use |
| shared_preferences | 2.5.6 | BSD-3-Clause | Use (simple settings) |
| local_auth | 3.0.2 | BSD-3-Clause | Optional (app lock) |
| flutter_launcher_icons | 0.14.4 | MIT | Use (dev) |
| flutter_native_splash | 2.4.8 | MIT | Use (dev) |
| google_mlkit_text_recognition | 1.0.3 | MIT wrapper + **closed ML Kit binaries** | Optional plugin, flagged |
| tesseract_ocr (Tesseract engine) | 0.6.0 | BSD-3 (wrapper) / Apache-2 (engine) | Optional, fully open |

---

## 5. Security of a PDF reader

**Threats:**
- **JavaScript** (`/JS`, `/OpenAction`, form calculate/validate scripts). Mitigated at build time: the pdfrx
  PDFium build has **no V8**, so scripts can't run. Never switch to the `pdfium-v8` variant.
- **Launch and URI actions.** `/Launch` (run a file), `/URI` (open a URL), `/SubmitForm` and `/GoToR` (remote file).
  Mitigation: handle links ourselves, never act on `/Launch`, always **confirm before opening external URLs**
  (show the full URL), allow only `http`, `https` and `mailto`, and block `file:`, `javascript:`, `intent:` and custom schemes.
  The app has no network access, so form submission can't happen.
- **Embedded files and attachments.** List them, never auto-open them, and export only by explicit user action, with
  a warning for executable types.
- **Malformed files and DoS.** Deep object recursion, huge xref tables, cyclic page trees, enormous page sizes
  (for example 200,000 × 200,000 pt), or a very high image count can freeze the renderer or exhaust memory.
- **Decompression bombs.** A FlateDecode stream that expands to gigabytes, or huge JBIG2/JPX images. Text extraction and
  rendering can allocate without limit.
- **PDFium memory-safety bugs.** These are an ongoing stream. 2026 examples include use-after-free bugs CVE-2026-9958 (fixed in
  Chrome 148.0.7778.216) and CVE-2026-11303 / -11304 / -11306 / -11307 (fixed in Chrome 149.0.7827.53, with "arbitrary code
  in sandbox via crafted PDF" and CVSS 8.8 for -11303). Inside Chrome these bugs are contained by the renderer sandbox. **Inside our
  app there is no such sandbox**, so PDFium runs in the app process.

**Mitigations:**
1. **Keep pdfrx and PDFium current.** pdfrx tracks bblanchon releases closely (chromium/8125 at the time of writing).
   Use Dependabot or Renovate and ship updates promptly. Record the PDFium build number on the About screen.
2. **Ship no network permission** (remove `INTERNET` from the release AndroidManifest). An exploit then has no
   way to send data out, which is a big real-world mitigation.
3. **Isolate the work.** Run text extraction, search indexing and thumbnail generation in background isolates or queues (pdfrx
   already schedules PDFium work off the UI thread). For desktop, consider a separate helper process.
4. **Timeouts and cancellation.** Use pdfrx cancellation tokens for render, cap per-page render time, and show a
   "this page is taking long" placeholder instead of hanging.
5. **Size limits.** Warn above about 500 MB or 10,000 pages. Clamp render bitmap dimensions (for example to 8,192 px at most per side
   and a total pixel budget). Use the shared image memory budget.
6. **Fail safe on malformed files.** Catch exceptions per page so that one bad page doesn't kill the document
   (pdfrx 2.8 opens documents with unloadable pages). Offer "open read-only and copy" for corrupt files.
7. **Write safely.** Write to a temp file, fsync, verify that the output reopens, and only then atomically rename. Keep the
   original until the user confirms. This also solves "lost annotations" and "overwritten originals".
8. **Fuzz** the app's own parsers (DOCX/OOXML via archive, the sidecar annotation format) and cap zip-entry
   sizes and counts to resist zip bombs.

Sources: [OpenCVE CVE-2026-9958](https://app.opencve.io/cve/CVE-2026-9958),
[CVE-2026-11303](https://www.sentinelone.com/vulnerability-database/cve-2026-11303/),
[CVE-2026-11304](https://app.opencve.io/cve/CVE-2026-11304),
[CVE-2026-11307](https://radar.offseq.com/threat/cve-2026-11307-use-after-free-in-google-chrome-3c71d79d),
[pdfium-binaries](https://github.com/bblanchon/pdfium-binaries),
[pdfrx build hook](https://github.com/espresso3389/pdfrx/blob/master/packages/pdfium_dart/hook/build.dart).

---

## 6. Feature list

**An honest note on difficulty without paid SDKs:**
- **Real PDF annotation objects** (highlight, ink or note `/Annot`s that Acrobat and Preview can see) are possible
  through raw PDFium FFI (`FPDFAnnot_*`), but pdfrx has no wrapper. The cheaper alternative is to store
  annotations in a sidecar database and **flatten** them on export (render them into page content, or use `pdf` to overlay).
  Plan this as: sidecar first, flatten on export, and real `/Annot` writing later.
- **Filling form field values** needs PDFium's `FORM_*` and `FPDFAnnot_SetStringValue` through FFI, and getting
  appearance streams right is tricky. Treat it as a stretch goal. XFA forms are unsupported (no XFA build).
- **High-fidelity DOCX-to-PDF** would need a layout engine. That is unrealistic offline without LibreOffice (MPL, about 100 MB+) or
  a paid SDK. Plan for *basic* DOCX (paragraphs, headings, bold/italic, lists, images) via archive + `pdf`.
- **Reflow (a "Liquid Mode" equivalent)** is hard: text order, columns and tables. A simple "text view" built from
  `loadStructuredText` with font-size grouping is achievable, but true reflow is not.
- **Editing existing text** in a PDF (changing glyphs) is very hard. Out of scope; use "whiteout + add text" instead.

### Viewing
| Feature | Priority |
|---|---|
| Open from file picker, "Open with" and the share sheet. Recent files and library | Must have |
| Smooth continuous scroll, pinch and double-tap zoom, tiled sharp rendering | Must have |
| Tap to hide chrome, page indicator, fast scrubber, go to page (including page labels) | Must have |
| Outline/TOC, thumbnails grid, bookmarks | Must have |
| In-document search with a hit list, text selection and copy | Must have |
| Internal links and back/forward history. External links with confirmation | Must have |
| Remember position, zoom and mode per document | Must have |
| Password-protected PDFs | Must have |
| Dark, sepia and inverted page themes. Keep screen awake | Must have |
| Horizontal paged mode, two-page spreads, RTL order | Nice to have |
| Auto-crop margins, split scanned spreads | Nice to have |
| Library-wide full-text search (FTS5) | Nice to have |
| Simple text reflow view | Nice to have (hard) |
| Read aloud (on-device TTS) | Nice to have |

### Editing
| Feature | Priority |
|---|---|
| Page organize: reorder, rotate, delete, insert, extract (pdfrx `pages` + `encodePdf`) | Must have |
| Merge PDFs, split by range | Must have |
| Highlight, underline, strikeout, freehand ink, text notes (sidecar storage, undo/redo) | Must have |
| Add text box, signature (drawn or image), whiteout rectangle (flattened on export) | Must have |
| Images or camera to PDF (`createFromJpegData` / `pdf`) | Must have |
| Write true `/Annot` objects that other apps can edit | Nice to have (hard, FFI) |
| Fill AcroForm fields | Nice to have (hard, FFI) |
| OCR scanned pages into a searchable text layer | Nice to have |
| Edit existing text | Out of scope |

### Export
| Feature | Priority |
|---|---|
| Save as a new copy by default. Atomic "Replace original" with confirmation | Must have |
| Share or export the PDF (flattened annotations) | Must have |
| Export annotations and highlights as Markdown or text | Must have |
| Export pages as PNG/JPEG. Extract text | Nice to have |
| Basic DOCX-to-PDF (archive + `pdf`) | Nice to have (low fidelity) |
| PDF-to-DOCX | Nice to have (text-only, low fidelity) |
| Compress (downsample images) | Nice to have |
| Print | Nice to have |

### Platform
| Feature | Priority |
|---|---|
| Android 8+ and iOS 15+; Files app and SAF integration; persisted URI permissions | Must have |
| Android "Open with" for application/pdf; iOS document types and "Open in place" | Must have |
| Tablet layouts, split-screen, keyboard and mouse/trackpad support | Must have |
| Apple Pencil and stylus pressure for ink, palm rejection | Nice to have |
| Desktop builds (macOS, Windows, Linux) | Nice to have |
| F-Droid build (no ML Kit) | Nice to have |

### Security and privacy
| Feature | Priority |
|---|---|
| No network permission, no analytics, no account, no ads | Must have |
| No JavaScript (non-V8 PDFium); block `/Launch`; confirm before external URLs | Must have |
| Size and render limits, timeouts, crash-safe writes | Must have |
| Embedded files listed but never auto-opened | Must have |
| Remove password / add password (`encodePdf(removeSecurity:)`; adding needs FFI) | Nice to have |
| Optional app lock (local_auth). Strip metadata on export | Nice to have |
| Redaction (true content removal, not just a black box) | Nice to have (hard; must be correct or omitted) |

### Design and accessibility
| Feature | Priority |
|---|---|
| Material 3 and Cupertino-appropriate controls; light and dark; dynamic color | Must have |
| Large touch targets, screen-reader labels for all chrome, respect text scaling | Must have |
| Reduced-motion setting honored | Must have |
| Localization-ready (ARB), RTL UI | Must have |
| High-contrast page themes; adjustable scrubber side for left-handed use | Nice to have |
| Accessibility of PDF content (exposing extracted text to TalkBack and VoiceOver) | Nice to have |

---

## 7. Recommended stack

Build PdfReader in **Flutter** (Dart 3, Impeller) on **pdfrx 2.12.x (MIT)**. It brings PDFium
(BSD/Apache, the *non-V8, non-XFA* bblanchon build) for rendering, text with character boxes, search, links, outline,
passwords, and page assembly with `encodePdf`. Use the pure-Dart **`pdf` 3.13 (Apache-2)** package to generate new PDFs (images to PDF,
basic DOCX to PDF via **archive (MIT)**, flattened annotation export) and **image (MIT)** for raster conversion.
Store app state, sidecar annotations and a full-text index in **drift (MIT) on SQLite**, manage state with
**flutter_riverpod (MIT)**, and navigate with **go_router (BSD-3)**. Handle I/O with **file_picker (MIT)**, **share_plus (BSD-3)** and
**receive_sharing_intent (Apache-2)**, or a small native channel, plus **path_provider (BSD-3)**. Use
**flutter_launcher_icons** and **flutter_native_splash** (MIT) for branding. OCR is an optional module: use **Tesseract (Apache-2)**
in the fully open build, and **ML Kit** (closed binaries) only as a clearly labeled optional add-on. Release the app under a
permissive license (MIT or Apache-2) and avoid MuPDF (AGPL), Poppler (GPL), Syncfusion, Nutrient/PSPDFKit and Apryse (all commercial). For the
hard parts (real `/Annot` writing, form filling), add a thin in-house FFI layer over PDFium through `pdfium_dart` and
`useNativeDocumentHandle()`, rather than buying an SDK.
