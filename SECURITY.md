# Security and privacy

PdfReader opens files from anywhere: email, downloads, chat apps. Some of these files may be made to attack a PDF reader.
This page explains what PdfReader does with your data and how it protects you.

---

## What PdfReader does and does not do with your data

### It does not
- **Use the internet.** The Android release app has **no internet permission at all**. Android itself blocks every network
  connection. The iPhone app makes **no network calls**.
- **Collect anything.** No analytics, no ads, no tracking, no crash reporting, no usage statistics.
- **Ask you to sign in.** There are no accounts.
- **Upload files.** All work (viewing, editing, export, PDF to DOCX, images to PDF) happens on your device.
- **Ask for storage permission.** It uses the system file picker. You choose each file. PdfReader can only read the files you pick
  or open with it.

### It does
- **Keep its data in app-private storage.** Recent files, reading positions, notes, signatures and settings are stored in the app's
  private folder. Other apps cannot read this folder.
- **Wipe temporary files.** Scratch files are deleted every time the app starts, and after each export or share.
- **Turn off backups.** App data is not copied to Google or iCloud backups, so it never leaves the device that way.
  (Android: `android:allowBackup="false"` and data-extraction rules exclude everything.)

> **Note for developers:** Flutter **debug** and **profile** builds add the internet permission so that hot reload and the
> debugger work. Only **release** builds are free of it. Check with:
> `aapt dump permissions build/app/outputs/flutter-apk/app-release.apk`

---

## How the protections work

### No JavaScript
PDF files can contain JavaScript. Attackers often use it. PdfReader uses **PDFium built without the V8 JavaScript engine and
without XFA**. Scripts inside a PDF cannot run, because there is no engine to run them.

Evidence (binary sources, hashes, and how we checked that no V8/XFA is present) is in [SECURITY_NOTES.md](SECURITY_NOTES.md).

### No automatic actions
A PDF cannot make PdfReader do anything by itself.
- **Launch** actions (start a program) are never run.
- **Embedded files** (attachments) are never opened automatically.
- **Web links** (URI actions) never open by themselves.
- When **you** tap a link, PdfReader shows the **full address** and asks before it opens it.
- Only `http`, `https` and `mailto` links can be opened. Other kinds (`file:`, `javascript:`, `intent:`, `content:`, custom
  app links, or broken addresses) are blocked, and PdfReader tells you so.
- Links longer than 2,048 characters are blocked.
- Links that jump to another page in the same document work directly.

### Defences against broken or harmful files
Every PDF is treated as untrusted. PdfReader has hard limits (`lib/core/security/limits.dart`):

| Limit | Value |
|---|---|
| Biggest file it opens | 2 GiB |
| Most pages | 20,000 |
| Biggest image drawn for one page or tile | 16 million pixels (about 64 MB) |
| Biggest page side it accepts | 14,400 points (the PDF spec limit) |
| Time to open a file | 30 seconds |
| Time to draw one page | 15 seconds |
| Time to read the text of one page | 10 seconds |
| Most characters read from one page | 200,000 |
| Most files in one merge | 50 |

If a file goes over a limit, PdfReader stops that work and shows a message. It does not freeze or crash.
One bad page does not stop you from reading the other pages.

### Your originals are safe
- **Save as copy** is the default. PdfReader writes a new file, for example `report (edited).pdf`.
- **Replace original** only happens when you choose it and confirm.
- Writes are **atomic**: PdfReader writes to a temporary file first and then swaps it in. If the phone turns off in the middle,
  the old file is still complete.

### Minimal permissions
- No internet, no storage, no camera-roll, no contacts, no location permission.
  (No camera or photo access is used.)
- Files come in through the system file picker, **Open with** or **Share**.

### Release builds
- Signed with the project's release key.
- Code shrinking and obfuscation are on (`--obfuscate --split-debug-info`).
- Not debuggable.

### Dependencies
- Package versions are **pinned**: the PDF, file and sharing packages use exact versions in `pubspec.yaml`, and `pubspec.lock` fixes every version.
- Only **permissive open-source licenses** (MIT, BSD, Apache-2.0). No closed or paid SDKs.
- Dependencies are checked for known vulnerabilities with **OSV** in CI.
  See [.github/workflows/security.yml](.github/workflows/security.yml) and [.github/workflows/ci.yml](.github/workflows/ci.yml).
- PDFium is the most important dependency. Security fixes in PDFium are shipped as soon as pdfrx releases them.

---

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

1. Go to the repository: https://github.com/MANISH50/PdfReader
2. Open the **Security** tab.
3. Click **Report a vulnerability**. This creates a private report (GitHub Security Advisory). Only the maintainers can see it.



Please include:
- What you found and what an attacker could do.
- Steps to reproduce. A sample PDF helps a lot (attach it to the private report).
- The PdfReader version and your device and OS version.

We will reply as soon as we can, usually within 7 days. We will tell you when a fix is released and credit you if you want.

---

## Supported versions

Only the **latest release** gets security fixes. Please update to the newest version.

| Version | Security fixes |
|---|---|
| Latest release | Yes |
| Older releases | No |


