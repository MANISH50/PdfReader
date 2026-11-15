# Security notes (technical input for SECURITY.md)

Status as of 2026-11-15, pdfrx 2.12.1 / pdfrx_engine 0.9.2 / pdfium_dart 0.4.2 / pdfium_flutter 0.4.2.

## 1. PDF engine provenance

| Platform | Binary | Source | Integrity |
|---|---|---|---|
| Android (arm, arm64, x86, x64) | `libpdfium.so` | `pdfium_dart-0.4.2/hook/build.dart`: `https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F8125/pdfium-android-<arch>.tgz` | **No checksum pinned upstream** (only the release tag). We record the hash ourselves (below). |
| Linux | `libpdfium.so` | same hook, `pdfium-linux-<arch>.tgz` | not pinned upstream |
| Windows | `pdfium.dll` | same hook, `pdfium-win-<arch>.tgz` | not pinned upstream |
| macOS | `PDFium.xcframework` (linked into the app; the hook's `pdfium-mac-*.tgz` dylib is only used by `flutter test`) | `pdfium_flutter-0.4.2/darwin/pdfium_flutter.podspec` + `Package.swift`: `https://github.com/espresso3389/pdfium-xcframework/releases/download/v158.0.8125.0-20261029-150241/PDFium-chromium-8125-20261029-150241.xcframework.zip` | **SHA-256 pinned**: `4e83df9e096b98963070a91e1c8fe7252d5c3a80d505e8acfda3f18ac904230d` (podspec verifies it and aborts on mismatch; SwiftPM `checksum:` the same) |
| iOS | same xcframework | same | same pin; `pdfium_dart/hook/link.dart` drops the downloaded asset on iOS |

Also built from source on every platform: `pdfrx_pdfium_gate` (tiny C file in `pdfium_dart-0.4.2/src/pdfrx_pdfium_gate.c`).

Observed Android arm64 `libpdfium.so` in our release APK (chromium/8125):
`de19db1c0fb33579bca6ace903af7ccb9d03ad1d3f6c5202970d8d79d7538303` (6,598,376 bytes).
Gap: the Android/desktop download is trusted on first use (GitHub TLS + release tag); bblanchon releases are immutable in practice but not cryptographically pinned. Mitigation for releases: compare the bundled hash with this value (`unzip -p app-release.apk lib/arm64-v8a/libpdfium.so | sha256sum`) and update it consciously when pdfrx is bumped.

**No V8 / XFA.** The hook downloads `pdfium-<os>-<arch>.tgz`; bblanchon publishes the JavaScript-enabled builds under a different name (`pdfium-v8-<os>-<arch>.tgz`). The xcframework is also the non-V8 build. Never switch to a `-v8` artifact.

## 2. What pdfrx does with document actions (verified in source)

- Form environment: `pdfrx_engine-0.9.2/lib/src/native/pdfrx_pdfium.dart` ~L1085 calls `FPDFDOC_InitFormFillEnvironment` with a zeroed `FPDF_FORMFILLINFO` (`version = 1`, `m_pJsPlatform = NULL`). Version 1 = no XFA; null JS platform = no JS callbacks even if a V8 build were used.
- `FORM_DoDocumentJSAction`, `FORM_DoDocumentOpenAction`, `FORM_DoPageAAction`, `FORM_OnAfterLoadPage` are never called anywhere in pdfrx/pdfrx_engine (grep). So `/OpenAction`, `/AA` and JavaScript never run.
- Links: `_processAnnotLink` (~L2105) only reads `PDFACTION_URI` and returns `Uri.tryParse(...)`; `_processAnnotDest` only follows `PDFACTION_GOTO`. `Launch`, `GoToR`, `GoToE`, embedded-file and other actions are ignored (return null). Text-detected web links come from `FPDFLink_LoadWebLinks`.
- Nothing auto-opens: link taps only reach the app through `PdfViewerParams.linkHandlerParams.onLinkTap` (`pdfrx-2.12.1/lib/src/widgets/pdf_viewer.dart` ~L1656). Our viewer routes them through `LinkPolicy.decide` + a confirmation dialog showing `LinkPolicy.displayUrl`.
- Attachments/embedded files: pdfrx exposes no API that extracts or opens them.
- Network code inside pdfrx: `PdfDocument.openUri`/`PdfViewer.uri` (`pdf_file_cache.dart`, package:http) and the default error banner (`pdf_error_widget.dart`) which calls `launchUrlString(pub.dev docs)` on tap. We never call `openUri`/`.uri` (enforced by `test/security/no_network_test.dart`), the release app has no INTERNET permission, and the viewer must keep a custom `errorBannerBuilder` so the default banner (raw error + stack trace + external link) is never shown.
- PDFium has **no allocation-limit API** (`FPDF_LIBRARY_CONFIG` only has font paths, V8 isolate/platform, renderer/font-library type). Hence the pre-scan below.

## 3. Safe-open pipeline (`lib/core/security/`)

| File | Purpose |
|---|---|
| `pdf_sniffer.dart` | `PdfSniffer.sniffFile(path, allowedRoots:, maxBytes:)`: regular file only (dirs, devices, pipes rejected), symlinks followed only if the real target is inside `allowedRoots` (refused if none given), size 1..2 GiB measured on the opened handle, `%PDF-` within the first 1024 bytes. Maps to `OpenFailure`. |
| `pdf_prescan.dart` | `prescanPdf(path)` (background isolate) — decompression-bomb guard, called by `PdfrxDocumentService.open` before PDFium sees the file. |
| `guarded.dart` | `withTimeout()` → `OperationTimeoutException`; `withOpenTimeout()` → `DocumentOpenException(OpenFailure.timeout)`; `TaskLimiter` (max concurrent, bounded queue, LIFO option for rendering, cancellation, per-task timeout; a slot is held until the abandoned work really ends). |
| `safe_filename.dart` | `SafeFilename.sanitize()` strips separators (incl. look-alike slashes), C0/C1 controls, bidi overrides (U+202A-E, U+2066-9, U+200E/F, U+061C), zero-width/format/tag chars, lone surrogates; Windows reserved chars and device names; leading `.`/`-`; 200-byte UTF-8 cap keeping the extension; optional forced extension (`a.exe` → `a.exe.pdf`). `childPath`/`uniqueChildPath` guarantee a direct child of the target dir, never a symlink, never overwrite. `PathGuard.isInside` (symlink-resolving containment). |
| `link_policy.dart` + `punycode.dart` | http/https/mailto only; blocks `user:pass@` credentials, mailto `attach`/unknown fields, >2048 chars. `displayUrl` is pure ASCII: non-ASCII hosts in RFC 3492 punycode (`xn--`), rest percent-encoded (makes bidi/invisible chars visible). `inspect()` adds warnings: IDN, existing punycode, IP literal, local network, plain http. Not a full UTS #46 implementation (no NFKC mapping) — by design it only needs to make every non-ASCII character visible. |

### Decompression-bomb pre-scan
QA finding: a 2.4 KB PDF with `[/FlateDecode /FlateDecode]` inflating to 1 GiB pushed the process to 2.26 GB RSS.
Design: index every `stream` (1 MiB window cache, dictionary parsed backwards up to 64 KiB), parse `/Filter` (incl. abbreviations), direct `/Length` (falls back to `endstream`), image `/Width /Height /BitsPerComponent /ColorSpace /ImageMask`. Then:
- skip streams whose worst case (`raw × 1032^flateLayers`) is under the cap (no work for typical content/fonts);
- inflate the rest worst-first with chained `ZLibDecoder` chunked sinks that only *count* bytes, aborting at 64 MiB per non-image stream, or at the declared image size + 12.5% + 1 MiB (max 512 MiB) for images;
- refuse without decoding: declared image > 512 MiB decoded; ≥2 amplifying filters in a chain that includes LZW/RunLength (not decoded by us); > 500,000 streams;
- 8 s time budget → `incomplete` (fail-open: the file opens; budget is spent worst-first so padding cannot hide a nested bomb cheaply).
Outcome: `OpenFailure.unsafe` → "This file looks unsafe or too complex to open."
Measured (x86-64 desktop, `flutter test` JIT): bomb refused in 29 ms; image bomb (20000×20000 RGB) refused statically in 0 ms; all 10 normal test PDFs and a 29.5 MB generated 300-page document < 10 ms; a 126 MB worst-case file (120 × 1 MiB incompressible Flate streams, all of which must be inflated) 305–367 ms. Memory: ~1 MiB window + 64 KiB read buffer + zlib state. Expect 3–5× slower on mid-range phones.
Known gaps: encrypted documents (streams are ciphertext, inflate fails → treated as ok); object streams with indirect `/Length`/`/Width` (handled via `endstream`, dimensions unknown → 64 MiB cap); other amplifiers (JBIG2 / JPX / CCITT decoders) are bounded only by the declared-image-size check.

## 4. Android release hardening (`android/app/build.gradle.kts`)
- `applicationId = com.pdfreader.app` (namespace stays `com.pdfreader.pdfreader`), minSdk 24 (Flutter and url_launcher_android minimum), targetSdk 36, compileSdk = Flutter default.
- Release: `isMinifyEnabled`, `isShrinkResources`, `isDebuggable = false`, `isJniDebuggable = false`, `proguard-android-optimize.txt` + `proguard-rules.pro` (consumer rules of jni/jni_flutter/android_file_picker reviewed; Play Core dontwarn; `Log.v/d` stripped). `dependenciesInfo` block disabled (no Google-encrypted dependency blob in APK/AAB).
- Signing: env `PDFREADER_KEYSTORE_PATH/_PASSWORD`, `PDFREADER_KEY_ALIAS`, `PDFREADER_KEY_PASSWORD` (CI) or `android/key.properties` (local, gitignored, see `android/key.properties.example`). Missing → debug key with a loud warning; `PDFREADER_REQUIRE_RELEASE_SIGNING=true` makes that an error; partial config is always an error. v1 signing off (minSdk 24).
- `android.enableJetifier=false`.
- Build: `flutter build apk --release --obfuscate --split-debug-info=build/symbols` (keep `build/symbols` private for crash symbolication; it is gitignored).

## 5. Audits (`tool/security/`, `.github/workflows/security.yml`)
- `audit.sh`: `flutter pub outdated`, OSV check (`osv-scanner` if installed, else `osv_check.py`: api.osv.dev batch query, fallback to the OSV Pub dump on storage.googleapis.com), `license_check.py`, privacy test. Dev/CI tool only, never shipped.
- `check_manifest.sh <apk>`: fails on INTERNET/network-state/storage/media/location/camera/contacts/AD_ID etc., `debuggable`, `usesCleartextTraffic`; warns on `allowBackup`.
- `test/security/no_network_test.dart`: no `HttpClient`/sockets/WebSocket/package:http/dio/WebView/pdfrx `openUri`/`NetworkImage` in `lib/`; `url_launcher` only in files that gate through `LinkPolicy.decide`; no tracker/ads/crash SDKs in `pubspec.lock`; main manifest requests no network/storage permission.
- Results 2026-11-15: OSV (Pub dump, 12 advisories) — 0 known vulnerabilities in 118 hosted packages. Licenses: 125 permissive (MIT/BSD/Apache), 1 weak copyleft: `dbus 0.8.0` (MPL-2.0, transitive, Linux desktop only, used unmodified — acceptable). api.osv.dev is blocked from the build sandbox; CI uses the API.
- Verified 2026-11-15: `flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols` → 27.0 MB APK (`com.pdfreader.app`, minSdk 24, targetSdk 36). Release permissions: only `com.pdfreader.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (AndroidX signature-level, internal); no INTERNET; not debuggable; `check_manifest.sh` passes.
