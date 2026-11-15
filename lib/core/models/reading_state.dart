/// How pages are laid out in the viewer.
enum ReadingMode { continuous, singlePage, twoPage, reflow }

/// Page colour treatment. [night] dims and inverts page colours but keeps
/// images natural (hue-preserving invert); see ui/design_system/reading_theme.dart.
enum PageTheme { light, dark, sepia, night }

enum FitMode { width, page, custom }

/// Per-document reading state, persisted by [ReadingStateStore].
class ReadingState {
  const ReadingState({
    this.pageNumber = 1,
    this.zoom,
    this.fitMode = FitMode.width,
    this.mode = ReadingMode.continuous,
    this.bookmarks = const {},
    this.lastOpened,
  });

  /// 1-based page number.
  final int pageNumber;
  final double? zoom;
  final FitMode fitMode;
  final ReadingMode mode;

  /// 1-based page numbers.
  final Set<int> bookmarks;
  final DateTime? lastOpened;

  ReadingState copyWith({
    int? pageNumber,
    double? zoom,
    FitMode? fitMode,
    ReadingMode? mode,
    Set<int>? bookmarks,
    DateTime? lastOpened,
  }) =>
      ReadingState(
        pageNumber: pageNumber ?? this.pageNumber,
        zoom: zoom ?? this.zoom,
        fitMode: fitMode ?? this.fitMode,
        mode: mode ?? this.mode,
        bookmarks: bookmarks ?? this.bookmarks,
        lastOpened: lastOpened ?? this.lastOpened,
      );

  Map<String, Object?> toJson() => {
        'pageNumber': pageNumber,
        'zoom': zoom,
        'fitMode': fitMode.name,
        'mode': mode.name,
        'bookmarks': bookmarks.toList()..sort(),
        'lastOpened': lastOpened?.toIso8601String(),
      };

  factory ReadingState.fromJson(Map<String, Object?> j) => ReadingState(
        pageNumber: (j['pageNumber'] as num?)?.toInt() ?? 1,
        zoom: (j['zoom'] as num?)?.toDouble(),
        fitMode: FitMode.values.asNameMap()[j['fitMode']] ?? FitMode.width,
        mode: ReadingMode.values.asNameMap()[j['mode']] ?? ReadingMode.continuous,
        bookmarks: {
          for (final b in (j['bookmarks'] as List?) ?? const []) (b as num).toInt()
        },
        lastOpened: DateTime.tryParse((j['lastOpened'] as String?) ?? ''),
      );
}
