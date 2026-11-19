import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/pdf/document_service.dart';
import '../../core/security/link_policy.dart';
import '../../ui/design_system/tokens.dart';

/// Parses user input for "Go to page". Returns null if invalid.
int? parsePageInput(String input, int pageCount) {
  final n = int.tryParse(input.trim());
  if (n == null || n < 1 || n > pageCount) return null;
  return n;
}

Future<int?> showGoToPageDialog(BuildContext context, {required int current, required int pageCount}) {
  return showDialog<int>(
    context: context,
    builder: (c) => _GoToPageDialog(current: current, pageCount: pageCount),
  );
}

class _GoToPageDialog extends StatefulWidget {
  const _GoToPageDialog({required this.current, required this.pageCount});
  final int current;
  final int pageCount;
  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  late final _ctl = TextEditingController(text: '${widget.current}')
    ..selection = TextSelection(baseOffset: 0, extentOffset: '${widget.current}'.length);
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = parsePageInput(_ctl.text, widget.pageCount);
    if (n == null) {
      setState(() => _error = 'Enter a number from 1 to ${widget.pageCount}');
      return;
    }
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          key: const Key('viewer.goToPage.field'),
          controller: _ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          decoration: InputDecoration(
            labelText: 'Page (1–${widget.pageCount})',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('viewer.goToPage.ok'), onPressed: _submit, child: const Text('Go')),
        ],
      );
}

/// Asks for a document password. Returns null when cancelled.
Future<String?> showPasswordDialog(BuildContext context, {required bool retry, required String fileName}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (c) => _PasswordDialog(retry: retry, fileName: fileName),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.retry, required this.fileName});
  final bool retry;
  final String fileName;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctl.clear();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Password required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${widget.fileName}" is protected. Enter its password to open it.'),
            const SizedBox(height: Space.md),
            TextField(
              key: const Key('password.field'),
              controller: _ctl,
              autofocus: true,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: widget.retry ? 'Incorrect password. Try again.' : null,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              key: const Key('password.ok'),
              onPressed: () => Navigator.pop(context, _ctl.text),
              child: const Text('Open')),
        ],
      );
}

/// Shows the complete URL and asks before leaving the app.
Future<bool> confirmExternalLink(BuildContext context, Uri uri) async {
  final url = LinkPolicy.displayUrl(uri);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.open_in_new),
      title: Text(uri.scheme == 'mailto' ? 'Write an email?' : 'Open link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This document links to:'),
          const SizedBox(height: Space.sm),
          Container(
            width: double.maxFinite,
            padding: const EdgeInsets.all(Space.sm),
            decoration: BoxDecoration(
              color: Theme.of(c).colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
            ),
            child: SelectableText(url, key: const Key('linkUrl'), style: const TextStyle(fontFamily: 'monospace')),
          ),
          const SizedBox(height: Space.sm),
          const Text('Only continue if you trust this address. It will open in another app.'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            Navigator.pop(c, false);
          },
          child: const Text('Copy'),
        ),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open')),
      ],
    ),
  );
  return ok ?? false;
}

/// Friendly text for each open failure (never raw engine messages).
({String title, String message, IconData icon, bool canRetry}) describeFailure(OpenFailure f) => switch (f) {
      OpenFailure.notFound => (
          title: 'File not found',
          message: 'The file was moved, deleted, or access to it was revoked.',
          icon: Icons.search_off,
          canRetry: false,
        ),
      OpenFailure.tooLarge => (
          title: 'File too large',
          message: 'This file is larger than the 2 GB limit and cannot be opened safely.',
          icon: Icons.sd_card_alert_outlined,
          canRetry: false,
        ),
      OpenFailure.tooManyPages => (
          title: 'Too many pages',
          message: 'This document has more pages than can be opened safely.',
          icon: Icons.layers_clear_outlined,
          canRetry: false,
        ),
      OpenFailure.notPdf => (
          title: 'Not a PDF',
          message: 'This file does not look like a PDF document.',
          icon: Icons.description_outlined,
          canRetry: false,
        ),
      OpenFailure.corrupted => (
          title: "Can't open this PDF",
          message: 'The file is damaged or uses features that are not supported.',
          icon: Icons.broken_image_outlined,
          canRetry: true,
        ),
      OpenFailure.wrongPassword => (
          title: 'Wrong password',
          message: 'The password was not accepted.',
          icon: Icons.lock_outline,
          canRetry: true,
        ),
      OpenFailure.cancelled => (
          title: 'Password needed',
          message: 'This document is protected. Enter its password to read it.',
          icon: Icons.lock_outline,
          canRetry: true,
        ),
      OpenFailure.timeout => (
          title: 'Taking too long',
          message: 'The document took too long to open. It may be very complex or damaged.',
          icon: Icons.hourglass_disabled_outlined,
          canRetry: true,
        ),
      OpenFailure.unsafe => (
          title: 'Can\'t open safely',
          message: 'This file looks unsafe or too complex to open.',
          icon: Icons.gpp_bad_outlined,
          canRetry: false,
        ),
      OpenFailure.unsupported => (
          title: 'Not supported',
          message: 'This file type isn\'t supported.',
          icon: Icons.block_outlined,
          canRetry: false,
        ),
    };
