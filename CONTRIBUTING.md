# Contributing to PdfReader

Thank you for helping! Bug reports, ideas, translations and code are all welcome.

## Before you start
- For a big change, open an issue first so we can agree on the plan.
- For security problems, **do not** open a public issue. See [SECURITY.md](SECURITY.md).

## The one big rule: no network code
PdfReader is fully offline. Pull requests are **not accepted** if they:
- add the `INTERNET` permission to the Android release manifest,
- make any network call (HTTP, sockets, web views that load remote pages, and so on),
- add analytics, ads, crash reporting, tracking or accounts,
- add a package that does any of the above, or a closed-source or paid SDK.

Opening a link the user tapped (after the confirmation dialog in `LinkPolicy`) is the only exception. That hands the address
to the system browser; PdfReader itself still does not connect.

## Dependencies
- Only permissive licenses: MIT, BSD or Apache-2.0. No GPL, AGPL or commercial licenses.
- Pin exact versions for new packages in `pubspec.yaml` (for example `pdf: 3.13.1`, not `^3.13.1`). `pubspec.lock` is committed.
- Add new packages to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Code style
- Run `dart format .` before you commit.
- `flutter analyze` must show **no issues**. The rules are in `analysis_options.yaml` (strict casts, no `print`, and others).
- Follow the structure in the README: shared contracts live in `lib/core/`, screens in `lib/features/`,
  design tokens and widgets in `lib/ui/design_system/`.
- Every edit to a document must be a `Command` run through `UndoStack`, so undo and redo always work.
- Treat every PDF as untrusted. Respect the limits in `lib/core/security/limits.dart`.
- Never overwrite the user's original file without an explicit, confirmed choice. Write files atomically.
- Store app data only in the private folders from `AppDirs`. Put scratch files in `TempFiles`.
- Use plain, simple English in the UI. Give every button a screen-reader label.

## Tests
- Run `flutter test` before you open a pull request. All tests must pass.
- Add tests for new logic, especially for parsing, limits, links and file writing.
- If you fix a crash caused by a special PDF, add a small sample file to the tests if you can (only files you are allowed to share).

## Pull requests
1. Fork the repository and create a branch.
2. Keep each pull request small and about one thing.
3. Describe what you changed and how you tested it. Add screenshots for UI changes.

## License of contributions
PdfReader is released under the [MIT License](LICENSE).
By sending a contribution, you agree that it is released under the same MIT License,
and that you have the right to submit it.
