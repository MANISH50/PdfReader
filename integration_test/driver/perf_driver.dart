// Host-side driver for `flutter drive`. Saves the report data (frame timings,
// first-page times) and screenshots under build/ for CI artifacts.
//
//   flutter drive --profile --driver=integration_test/driver/perf_driver.dart \
//     --target=integration_test/performance_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final f = File('build/screenshots/$name.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
        return true;
      },
      responseDataCallback: (data) async {
        await writeResponseData(data);
        final lines = (data?['summary_lines'] as List?)?.cast<String>() ?? const <String>[];
        final out = File('build/perf_summary.txt');
        await out.parent.create(recursive: true);
        await out.writeAsString('${lines.join('\n')}\n', mode: FileMode.append);
        stdout.writeln(lines.join('\n'));
        stdout.writeln(const JsonEncoder.withIndent('  ').convert({
          for (final e in (data ?? const {}).entries)
            if (e.value is Map)
              e.key: {
                for (final k in (e.value as Map).keys)
                  if (k is String && (k.contains('90th') || k.contains('missed') || k == 'frame_count'))
                    k: (e.value as Map)[k],
              },
        }));
      },
      writeResponseOnFailure: true,
    );
