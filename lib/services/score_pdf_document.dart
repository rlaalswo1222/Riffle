import 'dart:typed_data';

class ScorePdfTextFragment {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const ScorePdfTextFragment({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
}

class ScorePdfPageText {
  final String fullText;
  final List<ScorePdfTextFragment> fragments;
  final List<ScorePdfTextFragment> characters;

  const ScorePdfPageText({
    required this.fullText,
    required this.fragments,
    this.characters = const <ScorePdfTextFragment>[],
  });

  static const ScorePdfPageText empty = ScorePdfPageText(
    fullText: '',
    fragments: <ScorePdfTextFragment>[],
    characters: <ScorePdfTextFragment>[],
  );
}

abstract class ScorePdfDocument {
  int get pagesCount;

  Future<double> pageAspectRatio(int pageIndex);

  Future<Uint8List?> renderPage(int pageIndex, {double scale = 2});

  /// PDF에 포함된 텍스트와 페이지 기준 좌표(0~1, 좌상단 원점)를 읽는다.
  Future<ScorePdfPageText> extractPageText(int pageIndex);

  /// PDF에 선으로 그려진 세로선(마디선·음표 기둥·괄호 갈고리 등).
  /// `[x, 위, 아래, 굵기]`이고 모두 페이지 기준 비율(0~1, 좌상단 원점)이다.
  /// 선 데이터를 읽을 수 없으면 빈 목록이다.
  Future<List<List<double>>> extractVerticalLines(int pageIndex) async =>
      const <List<double>>[];

  Future<void> close();
}
