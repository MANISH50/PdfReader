/// Decides what may happen when the user taps a link inside a PDF.
/// PDFs can never trigger navigation by themselves: JavaScript is not compiled
/// into our PDFium build, Launch/GoToE/embedded-file actions are ignored, and
/// URI links only ever open after the user confirms the full address.
enum LinkDecision {
  /// Internal destination: jump within the document, no confirmation needed.
  internal,

  /// External web/mail link: show full URL and ask before opening.
  confirmExternal,

  /// Anything else (file:, javascript:, intent:, content:, custom schemes,
  /// malformed): never open; tell the user it was blocked.
  blocked,
}

abstract final class LinkPolicy {
  static const allowedSchemes = {'http', 'https', 'mailto'};

  static LinkDecision decide({Uri? uri, bool hasInternalDest = false}) {
    if (uri == null) return hasInternalDest ? LinkDecision.internal : LinkDecision.blocked;
    if (!allowedSchemes.contains(uri.scheme.toLowerCase())) return LinkDecision.blocked;
    if (uri.scheme != 'mailto' && uri.host.isEmpty) return LinkDecision.blocked;
    if (uri.toString().length > 2048) return LinkDecision.blocked;
    return LinkDecision.confirmExternal;
  }

  /// Text to show in the confirmation dialog: always the complete URL.
  /// Uri.toString percent-encodes non-ASCII characters, so look-alike
  /// (homograph) hosts are visible. Security agent may refine (e.g. punycode).
  static String displayUrl(Uri uri) => uri.toString();
}
