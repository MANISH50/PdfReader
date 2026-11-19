import 'dart:typed_data';

import '../../core/documents/document_kind.dart';

/// A run of inline text with simple formatting. Plain data, so it can be
/// built in a background isolate and sent to the UI isolate.
class RSpan {
  const RSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.link,
    this.imageAlt,
  });

  /// Placeholder for an image that is never loaded (Markdown images, DOCX
  /// images inside tables). Takes no space in the searchable text.
  const RSpan.image(String alt)
      : this('', imageAlt: alt);

  final String text;
  final bool bold, italic, underline, strike, code;

  /// Link target as written in the document; opened only through LinkPolicy
  /// and the confirmation dialog.
  final String? link;
  final String? imageAlt;

  RSpan withText(String t) => RSpan(t,
      bold: bold, italic: italic, underline: underline, strike: strike, code: code, link: link, imageAlt: imageAlt);
}

String spansText(List<RSpan> spans) {
  if (spans.length == 1) return spans.first.text;
  final b = StringBuffer();
  for (final s in spans) {
    b.write(s.text);
  }
  return b.toString();
}

/// One item of the lazily built reader list.
sealed class RBlock {
  const RBlock();

  /// Text searched by find-in-document; renderers lay text out in the same
  /// order so hit offsets map back onto spans.
  String get searchText;
}

/// Paragraph, heading or list item.
final class TextBlock extends RBlock {
  const TextBlock(this.spans, {this.headingLevel = 0, this.marker, this.indent = 0, this.quoteDepth = 0});
  final List<RSpan> spans;

  /// 1-6 for headings, 0 for body text.
  final int headingLevel;

  /// List marker ("•", "3.", "☐"), if this is a list item.
  final String? marker;
  final int indent;
  final int quoteDepth;

  @override
  String get searchText => spansText(spans);
}

/// A line (or a short run of lines) of a plain-text file.
final class LineBlock extends RBlock {
  const LineBlock(this.text, {this.gapBefore = false});
  final String text;

  /// Extra space above (a paragraph break in proportional text).
  final bool gapBefore;

  @override
  String get searchText => text;
}

final class CodeBlock extends RBlock {
  const CodeBlock(this.text, {this.language, this.indent = 0, this.quoteDepth = 0});
  final String text;
  final String? language;
  final int indent;
  final int quoteDepth;

  @override
  String get searchText => text;
}

/// A table: rows of cells; each cell is a list of paragraphs.
final class TableBlock extends RBlock {
  const TableBlock(this.rows, {this.headerRows = 0});
  final List<List<List<List<RSpan>>>> rows;
  final int headerRows;

  int get columnCount => rows.fold(0, (m, r) => r.length > m ? r.length : m);

  /// Each paragraph of each cell, row by row, followed by '\n'.
  @override
  String get searchText {
    final b = StringBuffer();
    for (final row in rows) {
      for (final cell in row) {
        for (final para in cell) {
          b
            ..write(spansText(para))
            ..write('\n');
        }
      }
    }
    return b.toString();
  }
}

final class RuleBlock extends RBlock {
  const RuleBlock();
  @override
  String get searchText => '';
}

final class PageBreakBlock extends RBlock {
  const PageBreakBlock();
  @override
  String get searchText => '';
}

/// An embedded DOCX image ([bytes] already size-checked), or a placeholder
/// when [bytes] is null.
final class ImageBlock extends RBlock {
  const ImageBlock({this.bytes, this.alt = '', this.width, this.height});
  final Uint8List? bytes;
  final String alt;
  final int? width, height;
  @override
  String get searchText => '';
}

class ReaderDocument {
  const ReaderDocument({required this.kind, required this.blocks, this.monospace = false, this.notice});
  final DocumentKind kind;
  final List<RBlock> blocks;

  /// Plain text shown in a monospace font (code, data, logs).
  final bool monospace;

  /// Small banner shown above the content (DOCX fidelity note).
  final String? notice;
}

enum ReaderFailure { tooLarge, unsafe, damaged, timeout, unsupported, notFound }

class ReaderOpenException implements Exception {
  const ReaderOpenException(this.failure);
  final ReaderFailure failure;

  String get message => switch (failure) {
        ReaderFailure.tooLarge => 'This file is too large to open safely.',
        ReaderFailure.unsafe => 'This file looks unsafe or too complex to open.',
        ReaderFailure.damaged => 'This file looks damaged and couldn’t be opened.',
        ReaderFailure.timeout => 'Opening this file took too long.',
        ReaderFailure.unsupported => "This file type isn't supported.",
        ReaderFailure.notFound => 'The file was moved, deleted, or access to it was revoked.',
      };

  @override
  String toString() => 'ReaderOpenException($failure)';
}

/// Cooperative time budget checked by the parsers.
class ParseBudget {
  ParseBudget(this.limit) : _sw = Stopwatch()..start();
  final Duration limit;
  final Stopwatch _sw;
  void check() {
    if (_sw.elapsed > limit) throw const ReaderOpenException(ReaderFailure.timeout);
  }
}
