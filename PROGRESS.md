# PdfReader — Progress

_Lead updates this file after every merge._

## Done
- **Step 1 — Research**: `RESEARCH.md` (survey, premium-reading notes, stack + license table, security, feature list). Approved.
- **Step 2 — Skeleton**: Flutter 3.50 project (Android, iOS, macOS, Windows, Linux), pinned deps, strict lints, shared interfaces in `lib/core/`, design system in `lib/ui/design_system/`, router, settings, private storage, undo stack, link policy, security limits, core unit tests.

## In progress (lean mode: at most 2 agents at a time, to save usage)
Feature work is on per-agent branches; paused agents keep their work and resume later.

| Part | Status |
|---|---|
| Docs | Merged (final facts filled in at release) |
| Viewer | **Merged** after review fixes; editing tools wired in (Edit button, annotation overlay, Fill form, Save copy with annotations) |
| Editing | **Merged** (annotations + undo, signatures, organizer, merge/split, flatten to real PDF content, form filling, safe save). Gaps: edited copies of encrypted PDFs saved unencrypted; merge/split drop form fields & bookmarks |
| Export | **Merged** after review fixes (PNG/JPG, TXT, DOCX, PDF with edits; streamed zips; PDFium work on pdfrx worker) |
| QA | **Merged** (corpus, engine robustness tests, helpers, integration tests, CI). Follow-ups: fake DocumentService limits, split active content out of text_multi.pdf |
| Platform | **Merged** (open-with/share-in on Android & iOS with safe copy-in, share-out, system file picker, no INTERNET/storage permissions in release manifest). TODO: inbox cleanup when removed from recents; onboarding to use `DefaultAppInfo` + open-settings button |
| UI | **Merged** (design system, home, onboarding, settings, icon & splash, accessibility tests). TODO: multi-file merge from Home, real thumbnails |
| Security | **Merged** (decompression-bomb pre-scan, safe-open helpers, punycode link display, release hardening, audit tooling: 0 known vulns, licences OK) |

### Lean process
1. Max 2 agents at once; resume paused agents in the order above as slots free up.
2. Lead reviews and merges each branch directly (no separate reviewer agent per part).
3. Lead does small fixes and integration (wiring, keys, conflicts) itself.
4. One independent security review agent at the end, plus CI on GitHub Actions for emulator/iOS tests.

## Next
- Final security check (lead): done — links confirm-only, release manifest has no network/storage permissions, backups off.
- Signed release APK/AAB build → publish GitHub Release after owner OK.
- Step 4 — Full test run, CI emulator + iOS workflows, security review with malformed PDFs, performance checks, screenshots.
- Step 5 — Signed APK/AAB, docs, GitHub Release (after owner OK).

## Architecture contract (for all agents)
| Area | Location | Notes |
|---|---|---|
| Models | `lib/core/models/` | `DocumentRef`, `ReadingState`, `Annotation` (sealed, PDF-point coords), `ExportOptions`, `AppSettings` |
| Undo/redo | `lib/core/commands/undo_stack.dart` | Every edit is a `Command` run through `UndoStack` |
| Storage | `lib/core/storage/` | `AppDirs` (private dirs), `JsonStore` (atomic), `TempFiles` (wiped on start), stores for recents / reading state / annotations |
| Security | `lib/core/security/` | `SecurityLimits`, `LinkPolicy` |
| Engine contracts | `lib/core/pdf/` | `DocumentService` (open untrusted PDFs), `PageEditor`, `SaveService` |
| Export contract | `lib/core/export/exporter.dart` | `Exporter` |
| Platform contracts | `lib/platform/platform_services.dart` | `IncomingFileService`, `ShareService`, `FilePickService` |
| Wiring | `lib/core/providers.dart` | Each agent replaces only its own provider lines |
| Routes | `lib/app_router.dart` | `/`, `/onboarding`, `/settings`, `/viewer`, `/reader`, `/organize`, `/export` (document via `extra`); open any `DocumentRef` with `openDocumentRoute` / `documentRouteFor` (viewer for PDFs, reader otherwise) |
| Reader | `lib/core/documents/document_kind.dart`, `lib/features/reader/` | `sniffDocumentKind`; DOCX / Markdown / text parsed off-isolate into blocks, rendered lazily by `ReaderScreen` |
| Design | `lib/ui/design_system/` | tokens, `AppTheme`, `ReadingThemeSpec`, adaptive widgets |
