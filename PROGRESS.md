# PdfReader — Progress

_Lead updates this file after every merge._

## Done
- **Step 1 — Research**: `RESEARCH.md` (survey, premium-reading notes, stack + license table, security, feature list). Approved.
- **Step 2 — Skeleton**: Flutter 3.50 project (Android, iOS, macOS, Windows, Linux), pinned deps, strict lints, shared interfaces in `lib/core/`, design system in `lib/ui/design_system/`, router, settings, private storage, undo stack, link policy, security limits, core unit tests.

## In progress
- Step 3 — Parallel feature agents (Viewer, Editing, Export, Platform, UI, Security, QA, Docs).

## Next
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
| Routes | `lib/app_router.dart` | `/`, `/onboarding`, `/settings`, `/viewer`, `/organize`, `/export` (document via `extra`) |
| Design | `lib/ui/design_system/` | tokens, `AppTheme`, `ReadingThemeSpec`, adaptive widgets |
