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
| Viewer | Fixing review findings (running) |
| Editing | Building (running) |
| Export | Review done → fixes ~half done (paused, next) |
| QA | Review done → small fixes (paused; lead finishes them) |
| Platform | Android build step (paused, after Export) |
| UI | Nearly done (paused, after Platform) |
| Security | Pre-scan for decompression bombs in progress (paused, last) |

### Lean process
1. Max 2 agents at once; resume paused agents in the order above as slots free up.
2. Lead reviews and merges each branch directly (no separate reviewer agent per part).
3. Lead does small fixes and integration (wiring, keys, conflicts) itself.
4. One independent security review agent at the end, plus CI on GitHub Actions for emulator/iOS tests.

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
