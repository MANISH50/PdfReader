import 'punycode.dart';

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
  /// embedded credentials, mailto attachments, malformed): never open; tell
  /// the user it was blocked.
  blocked,
}

/// Reasons to draw the user's attention to a link in the confirmation dialog.
enum LinkWarning {
  /// Host contains non-ASCII characters (possible look-alike/homograph);
  /// it is displayed in punycode.
  internationalizedHost,

  /// Host is already punycode (`xn--`) in the PDF.
  punycodeHost,

  /// Host is a raw IP address.
  ipAddressHost,

  /// Host is localhost or a private/link-local network address.
  localNetworkHost,

  /// URL carries `user:password@` credentials (always blocked).
  embeddedCredentials,

  /// Plain-text http (not https).
  insecureScheme,
}

/// What the confirmation dialog should show for a link.
class LinkInspection {
  const LinkInspection({
    required this.decision,
    required this.displayUrl,
    required this.displayHost,
    required this.warnings,
  });

  final LinkDecision decision;

  /// Complete URL, ASCII only (punycode host, percent-encoded rest).
  final String displayUrl;

  /// The host (or mail domain) to emphasize, ASCII only. Empty if none.
  final String displayHost;

  final Set<LinkWarning> warnings;
}

abstract final class LinkPolicy {
  static const allowedSchemes = {'http', 'https', 'mailto'};

  /// mailto query fields we accept; anything else (notably `attach`,
  /// `attachment`, `file`, which some mail clients honour to attach local
  /// files) blocks the link.
  static const allowedMailtoFields = {'to', 'cc', 'bcc', 'subject', 'body', 'in-reply-to'};

  static const int maxUrlLength = 2048;

  static LinkDecision decide({Uri? uri, bool hasInternalDest = false}) {
    if (uri == null) return hasInternalDest ? LinkDecision.internal : LinkDecision.blocked;
    final scheme = uri.scheme.toLowerCase();
    if (!allowedSchemes.contains(scheme)) return LinkDecision.blocked;
    if (uri.toString().length > maxUrlLength) return LinkDecision.blocked;
    if (uri.userInfo.isNotEmpty) return LinkDecision.blocked;
    if (scheme == 'mailto') {
      if (!uri.path.contains('@') && !uri.hasQuery) return LinkDecision.blocked;
      if (uri.hasQuery) {
        final Map<String, List<String>> fields;
        try {
          fields = uri.queryParametersAll;
        } on FormatException {
          return LinkDecision.blocked;
        }
        if (fields.keys.any((k) => !allowedMailtoFields.contains(k.toLowerCase()))) {
          return LinkDecision.blocked;
        }
      }
      return LinkDecision.confirmExternal;
    }
    if (uri.host.isEmpty) return LinkDecision.blocked;
    return LinkDecision.confirmExternal;
  }

  /// Text to show in the confirmation dialog: always the complete URL, in
  /// ASCII. Non-ASCII hosts are shown in punycode (`xn--...`) so look-alike
  /// (homograph) hosts are obvious; the rest stays percent-encoded, which
  /// also makes bidi-override and invisible characters visible.
  static String displayUrl(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'mailto') {
      final path = _mailtoAsciiPath(uri.path);
      return 'mailto:$path${uri.hasQuery ? '?${uri.query}' : ''}${uri.hasFragment ? '#${uri.fragment}' : ''}';
    }
    if (!uri.hasAuthority) return uri.toString();
    final b = StringBuffer('$scheme://');
    if (uri.userInfo.isNotEmpty) b.write('${uri.userInfo}@');
    final host = asciiHost(uri.host);
    b.write(host.contains(':') ? '[$host]' : host);
    if (uri.hasPort) b.write(':${uri.port}');
    b.write(uri.path);
    if (uri.hasQuery) b.write('?${uri.query}');
    if (uri.hasFragment) b.write('#${uri.fragment}');
    return b.toString();
  }

  /// Full analysis for the confirmation dialog.
  static LinkInspection inspect(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final warnings = <LinkWarning>{};
    String rawHost;
    if (scheme == 'mailto') {
      final at = uri.path.lastIndexOf('@');
      rawHost = at >= 0 ? uri.path.substring(at + 1) : '';
    } else {
      rawHost = uri.host;
    }
    final unicodeHost = _decodeHost(rawHost);
    final host = asciiHost(rawHost);
    if (unicodeHost.runes.any((c) => c >= 0x80)) warnings.add(LinkWarning.internationalizedHost);
    if (host.split('.').any((l) => l.toLowerCase().startsWith('xn--')) &&
        !warnings.contains(LinkWarning.internationalizedHost)) {
      warnings.add(LinkWarning.punycodeHost);
    }
    if (_isIpLiteral(host)) warnings.add(LinkWarning.ipAddressHost);
    if (_isLocalNetwork(host)) warnings.add(LinkWarning.localNetworkHost);
    if (uri.userInfo.isNotEmpty) warnings.add(LinkWarning.embeddedCredentials);
    if (scheme == 'http') warnings.add(LinkWarning.insecureScheme);
    return LinkInspection(
      decision: decide(uri: uri),
      displayUrl: displayUrl(uri),
      displayHost: host,
      warnings: warnings,
    );
  }

  /// Host in ASCII form: percent-decoded, then punycode for non-ASCII labels.
  static String asciiHost(String host) {
    final decoded = _decodeHost(host);
    if (decoded.runes.every((c) => c < 0x80)) return decoded.toLowerCase();
    try {
      return Punycode.toAsciiHost(decoded);
    } on FormatException {
      return host; // keep percent-encoded form; still unambiguous
    }
  }

  static String _decodeHost(String host) {
    try {
      return Uri.decodeComponent(host);
    } on ArgumentError {
      return host;
    } on FormatException {
      return host;
    }
  }

  static String _mailtoAsciiPath(String path) {
    // path is "local@domain[,local@domain]" (percent-encoded by Uri).
    return path.split(',').map((addr) {
      final at = addr.lastIndexOf('@');
      if (at < 0) return addr;
      return '${addr.substring(0, at)}@${asciiHost(addr.substring(at + 1))}';
    }).join(',');
  }

  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  static bool _isIpLiteral(String host) => _ipv4.hasMatch(host) || host.contains(':');

  static bool _isLocalNetwork(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
    if (h.contains(':')) {
      return h == '::1' || h.startsWith('fe80') || h.startsWith('fc') || h.startsWith('fd');
    }
    if (!_ipv4.hasMatch(h)) return false;
    final o = h.split('.').map(int.parse).toList();
    return o[0] == 127 ||
        o[0] == 10 ||
        o[0] == 0 ||
        (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
        (o[0] == 192 && o[1] == 168) ||
        (o[0] == 169 && o[1] == 254);
  }
}
