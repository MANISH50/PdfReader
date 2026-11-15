import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'file_names.dart';
import 'platform_services.dart';

typedef ShareFn = Future<void> Function(ShareParams params);

/// Returns the logical-pixel size of the main window, used to anchor the
/// share popover on iPad (and macOS), where share_plus needs an origin rect.
typedef WindowSizeFn = Size? Function();

/// [ShareService] backed by share_plus (system share sheet; on Android files
/// go through share_plus' FileProvider with per-URI read grants).
class SharePlusShareService implements ShareService {
  SharePlusShareService({ShareFn? share, WindowSizeFn? windowSize})
      : _share = share ?? _defaultShare,
        _windowSize = windowSize ?? _defaultWindowSize;

  final ShareFn _share;
  final WindowSizeFn _windowSize;

  static Future<void> _defaultShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  static Size? _defaultWindowSize() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return null;
    final v = views.first;
    return v.physicalSize / v.devicePixelRatio;
  }

  @override
  Future<void> shareFiles(List<String> paths, {String? subject, Rect? origin}) async {
    if (paths.isEmpty) return;
    final files = <XFile>[];
    for (final path in paths) {
      if (!File(path).existsSync()) {
        throw FileSystemException('File to share does not exist', path);
      }
      files.add(XFile(path, mimeType: _mimeFor(path), name: sanitizeDisplayName(p.basename(path))));
    }
    await _share(ShareParams(
      files: files,
      subject: subject,
      title: subject,
      sharePositionOrigin: origin ?? _centerOrigin(),
      // Never fall back to a browser download or mailto: link.
      downloadFallbackEnabled: false,
      mailToFallbackEnabled: false,
    ));
  }

  /// A small rect in the middle of the window: harmless on phones and
  /// required by the iPad popover.
  Rect? _centerOrigin() {
    final size = _windowSize();
    if (size == null || size.isEmpty) return null;
    return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
  }

  static String _mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
        '.pdf' => 'application/pdf',
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.txt' => 'text/plain',
        '.md' => 'text/markdown',
        '.zip' => 'application/zip',
        '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };
}
