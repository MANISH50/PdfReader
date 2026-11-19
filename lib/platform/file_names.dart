/// File-name helpers for names that come from other apps (untrusted).
///
/// Mirrors `FileNames.sanitize` (Android, Kotlin) and
/// `IncomingFilesPlugin.sanitize` (iOS, Swift).
library;

const _fallback = 'document.pdf';
const _maxLength = 120;
const _banned = {':', '*', '?', '"', '<', '>', '|'};

bool _allowed(int c) {
  if (c < 0x20 || c == 0x7F) return false; // control chars, NUL
  if (c >= 0x202A && c <= 0x202E) return false; // bidi embeddings/overrides
  if (c >= 0x2066 && c <= 0x2069) return false; // bidi isolates
  if (c == 0x200E || c == 0x200F) return false; // LRM / RLM
  return !_banned.contains(String.fromCharCode(c));
}

/// Returns a display name safe to show and to use as a file name: no path
/// components, control or bidi-override characters, reserved characters or
/// leading dots, and at most 120 characters (keeping the extension).
String sanitizeDisplayName(String? raw) {
  var n = raw ?? '';
  final slash = n.lastIndexOf(RegExp(r'[/\\]'));
  if (slash >= 0) n = n.substring(slash + 1);
  n = String.fromCharCodes(n.runes.where(_allowed));
  n = n.trim().replaceFirst(RegExp(r'^\.+'), '').trim();
  if (n.isEmpty) return _fallback;
  final runes = n.runes.toList();
  if (runes.length > _maxLength) {
    final dot = n.lastIndexOf('.');
    final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
    final keep = _maxLength - ext.runes.length;
    n = String.fromCharCodes(runes.take(keep)).trimRight() + ext;
  }
  return n;
}

/// [sanitizeDisplayName], keeping the name's own extension (documents of any
/// supported kind); names without an extension get `.pdf`, as before.
String documentFileName(String? raw) {
  final n = sanitizeDisplayName(raw);
  return RegExp(r'\.[A-Za-z0-9]{1,10}$').hasMatch(n) ? n : '$n.pdf';
}

/// [sanitizeDisplayName] plus a guaranteed `.pdf` extension.
String pdfFileName(String? raw) {
  final n = sanitizeDisplayName(raw);
  return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
}
