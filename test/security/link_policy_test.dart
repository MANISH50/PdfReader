import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreader/core/security/link_policy.dart';
import 'package:pdfreader/core/security/punycode.dart';

String u(List<int> cps) => String.fromCharCodes(cps);

void main() {
  group('Punycode (RFC 3492 vectors)', () {
    test('encodes sample strings', () {
      // RFC 3492 7.1 (B) Chinese (simplified)
      expect(Punycode.encode(u([0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, 0x6587])),
          'ihqwcrb4cv8a8dqg056pqjye');
      // RFC 3492 7.1 (A) Arabic (Egyptian)
      expect(
          Punycode.encode(u([
            0x0644, 0x064A, 0x0647, 0x0645, 0x0627, 0x0628, 0x062A, 0x0643, 0x0644, //
            0x0645, 0x0648, 0x0634, 0x0639, 0x0631, 0x0628, 0x064A, 0x061F
          ])),
          'egbpdaj6bu4bxfgehfvwxn');
      // RFC 3492 7.1 (L) mixed with ASCII: "3<nen>B<gumi><kinpachi><sensei>"
      expect(Punycode.encode(u([0x33, 0x5E74, 0x42, 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F])),
          '3B-ww4c5e180e575a65lsy2b');
      expect(Punycode.encode('b${u([0xFC])}cher'), 'bcher-kva');
      expect(Punycode.encode('m${u([0xFC])}nchen'), 'mnchen-3ya');
      expect(Punycode.encode(u([0x43F, 0x440, 0x438, 0x43C, 0x435, 0x440])), 'e1afmkfd'); // "primer" (Cyrillic)
      expect(Punycode.encode('abc'), 'abc-');
      // Astral code point (emoji)
      expect(Punycode.encode(u([0x1F600])), 'e28h');
    });

    test('toAsciiHost converts only non-ASCII labels', () {
      expect(Punycode.toAsciiHost('b${u([0xFC])}cher.example.de'), 'xn--bcher-kva.example.de');
      expect(Punycode.toAsciiHost('example.com'), 'example.com');
      // Ideographic full stop acts as a dot.
      expect(Punycode.toAsciiHost('b${u([0xFC])}cher${u([0x3002])}de'), 'xn--bcher-kva.de');
    });
  });

  group('LinkPolicy.decide', () {
    test('keeps original contract', () {
      expect(LinkPolicy.decide(uri: Uri.parse('https://example.com/a')), LinkDecision.confirmExternal);
      expect(LinkPolicy.decide(uri: Uri.parse('HTTP://Example.com')), LinkDecision.confirmExternal);
      expect(LinkPolicy.decide(uri: Uri.parse('mailto:a@b.c')), LinkDecision.confirmExternal);
      expect(LinkPolicy.decide(hasInternalDest: true), LinkDecision.internal);
      expect(LinkPolicy.decide(), LinkDecision.blocked);
    });

    test('blocks dangerous schemes', () {
      for (final bad in [
        'javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'file:///etc/passwd', 'intent://x#Intent;end',
        'content://x/y', 'tel:123', 'sms:123', 'data:text/html,<script>', 'blob:https://a/b', 'ftp://a/b',
        'http:///nohost', 'myapp://x', 'android-app://com.x', 'vbscript:x', 'smb://host/share',
      ]) {
        expect(LinkPolicy.decide(uri: Uri.parse(bad)), LinkDecision.blocked, reason: bad);
      }
    });

    test('blocks embedded credentials', () {
      expect(LinkPolicy.decide(uri: Uri.parse('https://user:pass@example.com/')), LinkDecision.blocked);
      expect(LinkPolicy.decide(uri: Uri.parse('https://google.com@evil.example/')), LinkDecision.blocked);
      expect(LinkPolicy.decide(uri: Uri.parse('https://user@example.com/')), LinkDecision.blocked);
    });

    test('blocks mailto attachments and unknown fields', () {
      expect(LinkPolicy.decide(uri: Uri.parse('mailto:a@b.c?subject=Hi&body=x')), LinkDecision.confirmExternal);
      expect(LinkPolicy.decide(uri: Uri.parse('mailto:?to=a@b.c')), LinkDecision.confirmExternal);
      for (final bad in [
        'mailto:a@b.c?attach=/data/data/x/db',
        'mailto:a@b.c?ATTACHMENT=file:///sdcard/x',
        'mailto:a@b.c?subject=x&file=/etc/hosts',
        'mailto:',
        'mailto:nobody',
      ]) {
        expect(LinkPolicy.decide(uri: Uri.parse(bad)), LinkDecision.blocked, reason: bad);
      }
    });

    test('blocks huge URLs', () {
      final long = Uri.parse('https://example.com/${'a' * 5000}');
      expect(LinkPolicy.decide(uri: long), LinkDecision.blocked);
    });
  });

  group('LinkPolicy.displayUrl', () {
    test('shows IDN/homograph hosts in punycode', () {
      // "example" with Cyrillic small a (U+0430)
      final spoof = Uri.parse('https://ex${u([0x430])}mple.com/login');
      expect(LinkPolicy.displayUrl(spoof), 'https://xn--exmple-4nf.com/login');
      final insp = LinkPolicy.inspect(spoof);
      expect(insp.warnings, contains(LinkWarning.internationalizedHost));
      expect(insp.displayHost, 'xn--exmple-4nf.com');
      expect(insp.decision, LinkDecision.confirmExternal);
    });

    test('keeps port, path, query, fragment; output is pure ASCII', () {
      final uri = Uri.parse('https://b${u([0xFC])}cher.de:8443/p${u([0xE4])}th?q=${u([0x202E])}x#frag');
      final shown = LinkPolicy.displayUrl(uri);
      expect(shown, 'https://xn--bcher-kva.de:8443/p%C3%A4th?q=%E2%80%AEx#frag');
      expect(shown.runes.every((c) => c < 0x80), isTrue);
    });

    test('shows credentials so the user sees them', () {
      final uri = Uri.parse('https://paypal.com@evil.example/');
      expect(LinkPolicy.displayUrl(uri), 'https://paypal.com@evil.example/');
      expect(LinkPolicy.inspect(uri).warnings, contains(LinkWarning.embeddedCredentials));
      expect(LinkPolicy.inspect(uri).displayHost, 'evil.example');
    });

    test('mailto domain in punycode', () {
      final uri = Uri.parse('mailto:a@b${u([0xFC])}cher.de?subject=hi');
      expect(LinkPolicy.displayUrl(uri), 'mailto:a@xn--bcher-kva.de?subject=hi');
      expect(LinkPolicy.inspect(uri).displayHost, 'xn--bcher-kva.de');
    });

    test('flags IP, local network, plain http and existing punycode', () {
      expect(LinkPolicy.inspect(Uri.parse('http://192.168.1.1/admin')).warnings,
          containsAll([LinkWarning.ipAddressHost, LinkWarning.localNetworkHost, LinkWarning.insecureScheme]));
      expect(LinkPolicy.inspect(Uri.parse('https://[::1]/')).warnings, contains(LinkWarning.localNetworkHost));
      expect(LinkPolicy.displayUrl(Uri.parse('https://[::1]:8080/')), 'https://[::1]:8080/');
      expect(LinkPolicy.inspect(Uri.parse('https://xn--bcher-kva.de/')).warnings, {LinkWarning.punycodeHost});
      expect(LinkPolicy.inspect(Uri.parse('https://8.8.8.8/')).warnings, {LinkWarning.ipAddressHost});
      expect(LinkPolicy.inspect(Uri.parse('https://example.com/')).warnings, isEmpty);
    });

    test('non-authority URIs fall back to toString', () {
      expect(LinkPolicy.displayUrl(Uri.parse('javascript:alert(1)')), 'javascript:alert(1)');
    });
  });
}
