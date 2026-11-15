/// Minimal RFC 3492 Punycode encoder, used only to show internationalized
/// (possibly look-alike / homograph) host names in their ASCII `xn--` form.
///
/// This is deliberately NOT a full IDNA/UTS #46 implementation (no NFKC
/// mapping or validity checks): its only job is to make every non-ASCII
/// character in a host visible and unambiguous to the user.
abstract final class Punycode {
  static const int _base = 36;
  static const int _tMin = 1;
  static const int _tMax = 26;
  static const int _skew = 38;
  static const int _damp = 700;
  static const int _initialBias = 72;
  static const int _initialN = 0x80;
  static const int _maxInt = 0x7fffffff;

  /// Encodes one label (no `xn--` prefix). Throws [FormatException] on overflow.
  static String encode(String input) {
    final codePoints = input.runes.toList();
    final out = StringBuffer();
    var basicCount = 0;
    for (final c in codePoints) {
      if (c < 0x80) {
        out.writeCharCode(c);
        basicCount++;
      }
    }
    var h = basicCount;
    if (basicCount > 0) out.write('-');

    var n = _initialN;
    var delta = 0;
    var bias = _initialBias;
    while (h < codePoints.length) {
      var m = _maxInt;
      for (final c in codePoints) {
        if (c >= n && c < m) m = c;
      }
      if (m - n > (_maxInt - delta) ~/ (h + 1)) throw const FormatException('punycode overflow');
      delta += (m - n) * (h + 1);
      n = m;
      for (final c in codePoints) {
        if (c < n) {
          delta++;
          if (delta > _maxInt) throw const FormatException('punycode overflow');
        }
        if (c == n) {
          var q = delta;
          for (var k = _base;; k += _base) {
            final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
            if (q < t) break;
            out.writeCharCode(_digit(t + (q - t) % (_base - t)));
            q = (q - t) ~/ (_base - t);
          }
          out.writeCharCode(_digit(q));
          bias = _adapt(delta, h + 1, h == basicCount);
          delta = 0;
          h++;
        }
      }
      delta++;
      n++;
    }
    return out.toString();
  }

  /// Converts a host name to ASCII: every label containing non-ASCII
  /// characters becomes `xn--<punycode>`. IDNA dot variants are treated as dots.
  static String toAsciiHost(String host) {
    final normalized = host.replaceAll(RegExp('[\u3002\uFF0E\uFF61]'), '.');
    return normalized
        .split('.')
        .map((label) => label.runes.every((c) => c < 0x80) ? label : 'xn--${encode(label.toLowerCase())}')
        .join('.');
  }

  static int _digit(int d) => d < 26 ? d + 0x61 : d - 26 + 0x30; // a-z, 0-9

  static int _adapt(int delta, int numPoints, bool firstTime) {
    var d = firstTime ? delta ~/ _damp : delta ~/ 2;
    d += d ~/ numPoints;
    var k = 0;
    while (d > ((_base - _tMin) * _tMax) ~/ 2) {
      d ~/= _base - _tMin;
      k += _base;
    }
    return k + ((_base - _tMin + 1) * d) ~/ (d + _skew);
  }
}
