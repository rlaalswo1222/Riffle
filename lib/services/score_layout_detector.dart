import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image_lib;

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import 'score_pdf_document.dart';

/// PDF를 이미지로 읽어 실제 오선과 마디선 좌표를 찾는다.
///
/// 텍스트 분석이 줄별 시작 마디 수를 결정하고, 이 클래스는 그 줄 안의 실제
/// 마디 경계를 보정한다. 이미지 분석은 별도 isolate에서 실행해 큰 PDF를 올려도
/// 화면 입력이 멈추지 않게 한다.
class ScoreLayoutDetector {
  const ScoreLayoutDetector();

  Future<MeasureMap> refine(
    ScorePdfDocument document,
    MeasureMap original,
  ) async {
    if (original.isEmpty) return original;

    final Set<int> neededPages =
        original.anchors.map((ScoreAnchor anchor) => anchor.page).toSet();
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    int tinyDots = 0;
    for (final int page in neededPages) {
      final Uint8List? bytes = await document.renderPage(page, scale: 1.25);
      if (bytes != null && bytes.isNotEmpty) {
        // 악보 프로그램은 도돌이 점과 점음표 점을 음악 글꼴의 '.' 글자로
        // 찍는다. 글자 좌표가 픽셀보다 훨씬 정확하므로 함께 넘긴다.
        final List<List<double>> dots = <List<double>>[];
        try {
          final ScorePdfPageText text = await document.extractPageText(page);
          for (final ScorePdfTextFragment c in text.characters) {
            if (c.text != '.') continue;
            final double h = c.bottom - c.top;
            dots.add(<double>[c.centerX, c.centerY, c.right - c.left, h]);
            if (h < 0.006) tinyDots++;
          }
        } catch (_) {
          // 텍스트를 못 읽으면 픽셀 방식만 쓴다.
        }
        // 마디선은 PDF에 선 데이터로 들어 있다. 읽을 수 있으면 그림 대신 그걸 쓴다.
        List<List<double>> lines = const <List<double>>[];
        try {
          lines = await document.extractVerticalLines(page);
        } catch (_) {
          // 선 데이터를 못 읽으면 그림으로 찾는다.
        }
        pages.add(<String, Object?>{'page': page, 'bytes': bytes, 'dots': dots, 'lines': lines});
      }
    }
    if (pages.isEmpty) return original;

    final List<Map<String, Object?>> refinedJson = await compute(
      _detectScoreLayout,
      <String, Object?>{
        'pages': pages,
        // 점 글자가 있는 PDF면 도돌이를 글자로만 찾는다. 픽셀 방식은 조표의
        // ♯이나 점음표를 도돌이 점으로 자주 오인한다.
        'textDots': tinyDots >= 2,
        'anchors': original.anchors
            .map((ScoreAnchor anchor) => anchor.toJson())
            .toList(),
      },
    );
    if (refinedJson.isEmpty) return original;
    return MeasureMap(
      refinedJson.map(ScoreAnchor.fromJson).toList(growable: false),
    );
  }
}

@visibleForTesting
List<Map<String, Object?>> detectScoreLayoutForTesting(
  Map<String, Object?> input,
) =>
    _detectScoreLayout(input);

List<Map<String, Object?>> _detectScoreLayout(Map<String, Object?> input) {
  final List<ScoreAnchor> anchors = (input['anchors']! as List<dynamic>)
      .map((dynamic value) =>
          ScoreAnchor.fromJson(Map<String, dynamic>.from(value as Map)))
      .toList();
  final Map<int, _PreparedPage> pages = <int, _PreparedPage>{};
  final Map<int, List<List<double>>> dots = <int, List<List<double>>>{};
  final Map<int, List<List<double>>> vectorLines = <int, List<List<double>>>{};
  final bool textDots = input['textDots'] as bool? ?? false;
  for (final dynamic raw in input['pages']! as List<dynamic>) {
    final Map<dynamic, dynamic> page = raw as Map<dynamic, dynamic>;
    final image_lib.Image? decoded =
        image_lib.decodeImage(page['bytes'] as Uint8List);
    if (decoded != null) {
      pages[page['page'] as int] = _PreparedPage.fromImage(decoded);
      dots[page['page'] as int] = <List<double>>[
        for (final dynamic d in (page['dots'] as List<dynamic>?) ?? const <dynamic>[])
          <double>[for (final dynamic v in d as List<dynamic>) (v as num).toDouble()],
      ];
      vectorLines[page['page'] as int] = <List<double>>[
        for (final dynamic d in (page['lines'] as List<dynamic>?) ?? const <dynamic>[])
          <double>[for (final dynamic v in d as List<dynamic>) (v as num).toDouble()],
      ];
    }
  }

  final List<ScoreAnchor> result = <ScoreAnchor>[];
  for (int index = 0; index < anchors.length; index++) {
    final ScoreAnchor anchor = anchors[index];
    final _PreparedPage? page = pages[anchor.page];
    if (page == null) {
      result.add(anchor);
      continue;
    }

    final ScoreAnchor? next =
        index + 1 < anchors.length && anchors[index + 1].page == anchor.page
            ? anchors[index + 1]
            : null;
    result.add(
      _detectSystem(
        page,
        anchor,
        next,
        allowMeasureCountCorrection: index == anchors.length - 1,
        firstLine: index == 0,
        dots: textDots ? dots[anchor.page] : null,
        lines: vectorLines[anchor.page],
      ),
    );
  }
  return result
      .map((ScoreAnchor anchor) => anchor.toJson().cast<String, Object?>())
      .toList(growable: false);
}

ScoreAnchor _detectSystem(
  _PreparedPage page,
  ScoreAnchor anchor,
  ScoreAnchor? next, {
  required bool allowMeasureCountCorrection,
  bool firstLine = false,
  List<List<double>>? dots,
  List<List<double>>? lines,
}) {
  final int width = page.width;
  final int height = page.height;
  final Uint8List dark = page.dark;

  // 첫 줄은 마디 번호가 인쇄되지 않아 y가 짐작값이다. 오선 여러 개 중 아래쪽으로
  // 짐작했을 수도 있어서 페이지 위쪽부터 본다(제목·작곡가 줄에는 긴 가로선이 없다).
  final int regionTop = ((firstLine ? 0.04 : anchor.y - 0.018).clamp(0.0, 0.98) * height).round();
  final double rawBottom = next?.y ?? 0.97;
  final int regionBottom =
      ((rawBottom - 0.008).clamp(anchor.y + 0.025, 0.99) * height).round();
  final int scanLeft = (width * 0.035).round();
  final int scanRight = (width * 0.985).round();
  final int scanWidth = scanRight - scanLeft;

  final List<_RowPeak> rowPeaks = <_RowPeak>[];
  int? clusterStart;
  int bestRow = -1;
  int bestInk = -1;
  void flushRows() {
    if (clusterStart != null && bestRow >= 0) {
      rowPeaks.add(_RowPeak(bestRow, bestInk));
    }
    clusterStart = null;
    bestRow = -1;
    bestInk = -1;
  }

  for (int y = regionTop; y < regionBottom; y++) {
    int ink = 0;
    final int offset = y * width;
    for (int x = scanLeft; x < scanRight; x++) {
      ink += dark[offset + x];
    }
    if (ink >= scanWidth * 0.34) {
      clusterStart ??= y;
      if (ink > bestInk) {
        bestInk = ink;
        bestRow = y;
      }
    } else {
      flushRows();
    }
  }
  flushRows();
  if (rowPeaks.length < 5) return anchor;

  final int spacing = _staffSpacing(rowPeaks.map((e) => e.y).toList());
  if (spacing <= 0) return anchor;
  final List<int> staffRows = rowPeaks
      .where((peak) => peak.ink >= scanWidth * 0.42)
      .map((peak) => peak.y)
      .toList();
  if (staffRows.length < 5) return anchor;

  final List<_Gap> staffGaps = <_Gap>[];
  for (int i = 0; i < staffRows.length - 1; i++) {
    final int gap = staffRows[i + 1] - staffRows[i];
    if (gap >= spacing * 0.55 && gap <= spacing * 1.55) {
      staffGaps.add(_Gap(staffRows[i], staffRows[i + 1]));
    }
  }
  if (staffGaps.length < 3) return anchor;

  final List<int> horizontalSupport = List<int>.filled(width, 0);
  for (final int y in staffRows) {
    for (int x = scanLeft; x < scanRight; x++) {
      if (dark[y * width + x] != 0) horizontalSupport[x]++;
    }
  }
  final int supportThreshold = math.max(2, (staffRows.length * 0.42).ceil());
  final List<_Run> supportRuns = _runsWhere(
    scanLeft,
    scanRight,
    (int x) => horizontalSupport[x] >= supportThreshold,
    bridge: math.max(2, spacing ~/ 2),
  );
  if (supportRuns.isEmpty) return anchor;
  final _Run staffExtent = supportRuns.reduce(
    (_Run a, _Run b) => a.length >= b.length ? a : b,
  );
  if (staffExtent.length < width * 0.45) return anchor;

  final List<double> verticalScore = List<double>.filled(width, 0);
  for (int x = staffExtent.start; x <= staffExtent.end; x++) {
    int passed = 0;
    for (final _Gap gap in staffGaps) {
      final int fromY = gap.top + 1;
      final int toY = gap.bottom;
      int covered = 0;
      for (int y = fromY; y < toY; y++) {
        bool pixelDark = false;
        for (int dx = -1; dx <= 1; dx++) {
          final int sampleX = (x + dx).clamp(0, width - 1);
          if (dark[y * width + sampleX] != 0) {
            pixelDark = true;
            break;
          }
        }
        if (pixelDark) covered++;
      }
      final int samples = math.max(1, toY - fromY);
      // 마디선은 칸을 끝까지 덮는다. 3.5칸짜리 음표 기둥은 맨 위·아래 칸을
      // 다 못 덮으므로 여기서 걸러진다(한 보표 줄에서 기둥을 마디선으로 잡던 문제).
      if (covered / samples >= 0.9) passed++;
    }
    verticalScore[x] = passed / staffGaps.length;
  }

  final List<_LineCandidate> pixelCandidates = <_LineCandidate>[];
  final List<_Run> lineRuns = _runsWhere(
    staffExtent.start,
    staffExtent.end + 1,
    (int x) => verticalScore[x] >= 0.45,
    bridge: 1,
  );
  for (final _Run run in lineRuns) {
    int best = run.start;
    for (int x = run.start + 1; x <= run.end; x++) {
      if (verticalScore[x] > verticalScore[best]) best = x;
    }
    // 음표 기둥이 오선 전체를 덮는 일은 보표가 하나뿐인 줄에서만 생긴다.
    final double factor = staffGaps.length <= 4
        ? _beyondStaffFactor(dark, width, staffRows.first, staffRows.last, spacing, best, staffExtent)
        : 1;
    pixelCandidates.add(_LineCandidate(best, verticalScore[best] * factor));
  }
  // PDF 선 데이터가 있으면 그것으로 고른다. 그림 판독은 선을 못 읽는 PDF용이다.
  final List<_LineCandidate> vectorCandidates = lines == null || lines.isEmpty
      ? const <_LineCandidate>[]
      : _vectorCandidates(lines, width, height, staffRows, spacing, staffExtent);
  final List<_LineCandidate> candidates =
      vectorCandidates.length >= 3 ? vectorCandidates : pixelCandidates;
  final List<double>? thick = vectorCandidates.length >= 3
      ? _thickLines(lines!, width, height, staffRows, spacing)
      : null;
  int count = ((anchor.endMeasure ?? anchor.measure) - anchor.measure).round();
  if (count <= 0) return anchor;
  List<double>? boundaries;
  if (allowMeasureCountCorrection) {
    // 마지막 줄은 다음 줄 번호가 없어 마디 수를 추정한 값이다.
    // 모든 보표를 관통하는 선을 세어 실제 마디 수를 쓴다.
    final List<double> lines = _fullBarlines(
      candidates,
      staffExtent.start,
      staffExtent.end,
      spacing,
    );
    final int counted = lines.length - 1;
    if (counted > 0 && counted != count && counted <= count + 3) {
      boundaries = lines;
      count = counted;
    }
  }
  boundaries ??= _selectBoundaries(
    candidates,
    count,
    staffExtent.start,
    staffExtent.end,
  );
  // 선 데이터로 못 고르면 그림으로 찾은 후보로 한 번 더 해 본다.
  if (boundaries == null && !identical(candidates, pixelCandidates)) {
    boundaries = _selectBoundaries(pixelCandidates, count, staffExtent.start, staffExtent.end);
  }
  if (boundaries == null && allowMeasureCountCorrection && count > 1) {
    boundaries = _selectBoundaries(
      candidates,
      count - 1,
      staffExtent.start,
      staffExtent.end,
    );
    if (boundaries != null) count--;
  }
  if (boundaries == null) {
    // 마디선을 못 찾은 줄도 도돌이 점은 찾는다. 마디는 균등하게 나눈다.
    if (dots == null) return anchor;
    final double left = anchor.xStart * width, right = anchor.xEnd * width;
    final List<double> even = <double>[
      for (int k = 0; k <= count; k++) left + (right - left) * k / count,
    ];
    final (List<int> s, List<int> e) =
        _textRepeatMarks(dots, width, height, staffRows, spacing, even, thick: thick);
    return anchor.copyWith(
        y: firstLine ? _lineTop(anchor.y, staffRows.first, spacing, height) : anchor.y, repeatStarts: s, repeatEnds: e);
  }

  final List<int> repeatStarts = <int>[];
  final List<int> repeatEnds = <int>[];
  if (dots != null) {
    final (List<int> s, List<int> e) =
        _textRepeatMarks(dots, width, height, staffRows, spacing, boundaries, thick: thick);
    repeatStarts.addAll(s);
    repeatEnds.addAll(e);
  }
  for (int boundary = 0; dots == null && boundary < boundaries.length; boundary++) {
    if (_hasRepeatAtBoundary(
          dark,
          width,
          height,
          boundaries,
          boundary,
          staffRows,
          spacing,
          verticalScore: verticalScore,
          rightSide: true,
        ) &&
        boundary < boundaries.length - 1) {
      repeatStarts.add(boundary);
    }
    // 도돌이 끝(:‖)은 줄의 왼쪽 끝에 올 수 없다. 거기서 보이는 점은
    // 음자리표·조표다.
    if (boundary > 0 &&
        _hasRepeatAtBoundary(
          dark,
          width,
          height,
          boundaries,
          boundary,
          staffRows,
          spacing,
          verticalScore: verticalScore,
          rightSide: false,
        )) {
      repeatEnds.add(boundary);
    }
  }

  final double systemBottom = ((staffRows.last + spacing * 1.8) / height).clamp(
    anchor.y + 0.015,
    next?.y ?? 0.985,
  );
  return anchor.copyWith(
    y: firstLine ? _lineTop(anchor.y, staffRows.first, spacing, height) : anchor.y,
    xStart: boundaries.first / width,
    xEnd: boundaries.last / width,
    endMeasure: anchor.measure + count,
    barlines: boundaries.map((double x) => x / width).toList(growable: false),
    systemBottom: systemBottom,
    repeatStarts: repeatStarts,
    repeatEnds: repeatEnds,
  );
}

@visibleForTesting
(List<int>, List<int>) textRepeatMarksForTesting(
  List<List<double>> dots,
  int width,
  int height,
  List<int> staffRows,
  int spacing,
  List<double> boundaries, {
  List<double>? thick,
}) =>
    _textRepeatMarks(dots, width, height, staffRows, spacing, boundaries, thick: thick);

/// 도돌이 점 찾기 (PDF 글자 좌표).
///
/// 도돌이 점은 가운데 줄을 사이에 두고 2·3번째 칸에 하나씩 찍힌다. 점음표의
/// 점은 음표 높이를 따라가므로 같은 자리에 3·4번째 칸 점이 함께 있거나
/// 짝이 맞지 않는다. 보표가 여럿이면 두 보표 이상에서 같은 가로 위치여야 한다.
/// 점이 마디선 바로 왼쪽이면 끝(:‖), 아니면 앞 마디선 뒤의 시작(‖:)이다.
///
/// [thick]: PDF 선 데이터에서 찾은 굵은 세로선(도돌이표·끝세로줄의 굵은 선)의
/// x(픽셀). 주어지면 점 옆 2.5칸 안에 굵은 선이 있어야 도돌이표로 보고, 방향도
/// 점이 굵은 선의 왼쪽(:‖ 끝)인지 오른쪽(‖: 시작)인지로 정한다.
(List<int>, List<int>) _textRepeatMarks(
  List<List<double>> dots,
  int width,
  int height,
  List<int> staffRows,
  int spacing,
  List<double> boundaries, {
  List<double>? thick,
}) {
  final List<List<int>> staves = _groupStaves(staffRows, spacing);
  if (staves.isEmpty) return (const <int>[], const <int>[]);
  final List<List<double>> hits = <List<double>>[]; // [x, 보표 번호]
  for (int s = 0; s < staves.length; s++) {
    final List<int> staff = staves[s];
    final double sp = (staff[4] - staff[0]) / 4;
    final List<({double x, double pos, double h})> inStaff = <({double x, double pos, double h})>[];
    for (final List<double> d in dots) {
      final double x = d[0] * width, y = d[1] * height;
      if (x < boundaries.first - sp || x > boundaries.last + sp) continue;
      final double pos = (y - staff[0]) / sp;
      if (pos < -0.8 || pos > 4.8) continue;
      inStaff.add((x: x, pos: pos, h: d[3] * height));
    }
    inStaff.sort((a, b) => a.x.compareTo(b.x));
    int i = 0;
    while (i < inStaff.length) {
      int j = i + 1;
      while (j < inStaff.length && inStaff[j].x - inStaff[j - 1].x <= sp * 0.45) {
        j++;
      }
      final List<({double x, double pos, double h})> group = inStaff.sublist(i, j);
      bool isUpper(double pos) => pos >= 0.2 && pos <= 1.85;
      // 글자 상자가 위나 아래로 2~3칸 길게 잘못 잡히는 점이 있다. 어느 쪽
      // 끝이 맞는지는 PDF마다 달라서, 위쪽 점으로만 쓰고 양 끝을 다 본다.
      final bool upper = group.any((d) => d.h <= sp * 0.8
          ? isUpper(d.pos)
          : isUpper(d.pos - d.h / sp / 2 + 0.2) ||
              isUpper(d.pos + d.h / sp / 2 - 0.2));
      final bool lower = group.any((d) => d.pos >= 2.1 && d.pos <= 2.8 && d.h <= sp * 0.8);
      final bool below = group.any((d) => d.pos >= 3.2 && d.h <= sp * 0.8);
      if (lower && upper && !below) {
        hits.add(<double>[group.map((d) => d.x).reduce((a, b) => a + b) / group.length, s.toDouble()]);
      }
      i = j;
    }
  }
  final int needed = staves.length <= 1 ? 1 : 2;
  final Set<int> starts = <int>{}, ends = <int>{};
  final List<double> used = <double>[];
  for (final List<double> h in hits) {
    if (used.any((double u) => (u - h[0]).abs() <= spacing * 0.8)) continue;
    final int count = hits
        .where((List<double> o) => (o[0] - h[0]).abs() <= spacing * 0.8)
        .map((List<double> o) => o[1])
        .toSet()
        .length;
    if (count < needed) continue;
    used.add(h[0]);
    if (thick != null) {
      double? bar;
      for (final double t in thick) {
        if ((t - h[0]).abs() <= spacing * 2.5 && (bar == null || (t - h[0]).abs() < (bar - h[0]).abs())) {
          bar = t;
        }
      }
      if (bar == null) continue; // 굵은 선 없는 점 = 점음표 등
      final double tol = spacing * 1.5;
      if (h[0] < bar) {
        final int k = boundaries.indexWhere((double b) => b >= bar! - tol);
        if (k > 0) ends.add(k);
      } else {
        final int k = boundaries.lastIndexWhere((double b) => b <= bar! + tol);
        if (k >= 0 && k < boundaries.length - 1) starts.add(k);
      }
      continue;
    }
    int k = boundaries.indexWhere((double b) => b > h[0]);
    if (k < 0) k = boundaries.length - 1;
    if (k > 0 && (boundaries[k] - h[0]) <= spacing * 2.2 && boundaries[k] >= h[0]) {
      ends.add(k);
    } else if (k - 1 >= 0 && k - 1 < boundaries.length - 1) {
      starts.add(k - 1);
    }
  }
  return (starts.toList()..sort(), ends.toList()..sort());
}

List<List<int>> _groupStaves(List<int> staffRows, int spacing) {
  final List<List<int>> staves = <List<int>>[];
  for (int index = 0; index + 4 < staffRows.length;) {
    final List<int> group = staffRows.sublist(index, index + 5);
    final bool regular = <int>[0, 1, 2, 3].every((int gap) {
      final int difference = group[gap + 1] - group[gap];
      return difference >= spacing * 0.55 && difference <= spacing * 1.55;
    });
    if (regular) {
      staves.add(group);
      index += 5;
    } else {
      index++;
    }
  }
  return staves;
}

bool _hasRepeatAtBoundary(
  Uint8List dark,
  int width,
  int height,
  List<double> boundaries,
  int boundary,
  List<int> staffRows,
  int spacing, {
  required List<double> verticalScore,
  required bool rightSide,
}) {
  final int center = boundaries[boundary].round();
  final double previousWidth = boundary > 0
      ? boundaries[boundary] - boundaries[boundary - 1]
      : boundaries.length > 1
          ? boundaries[1] - boundaries[0]
          : spacing * 12;
  final double nextWidth = boundary + 1 < boundaries.length
      ? boundaries[boundary + 1] - boundaries[boundary]
      : previousWidth;
  final int leftReach = boundary == boundaries.length - 1
      ? math.min((previousWidth * 0.28).round(), spacing * 10)
      : math.min(
          (math.min(previousWidth, nextWidth) * 0.12).round(), spacing * 5);
  final int rightReach = boundary == 0
      ? math.min((nextWidth * 0.30).round(), spacing * 12)
      : math.min(
          (math.min(previousWidth, nextWidth) * 0.12).round(), spacing * 5);

  // 첫 마디의 도돌이 시작표는 음자리표·조표·박자표 뒤에 놓인다. 이 구간
  // 전체를 훑으면 음자리표의 두 둥근 부분을 도돌이 점으로 오인하므로,
  // 첫 마디 너비의 앞쪽 18%는 건너뛴다. 반대로 도돌이 종료표는 경계의
  // 왼쪽 점만 보므로 첫 경계에서 오른쪽(음자리표 쪽)까지 넓히지 않는다.
  final int searchStart = boundary == 0 && rightSide
      ? center + math.min((nextWidth * 0.18).round(), spacing * 7)
      : center - leftReach;
  final int searchEnd = boundary == 0 && !rightSide
      ? center + math.min((nextWidth * 0.05).round(), spacing * 2)
      : center + rightReach;
  for (int x = math.max(0, searchStart);
      x <= math.min(width - 1, searchEnd);
      x++) {
    if (verticalScore[x] < 0.42) continue;
    if (_hasRepeatDots(
      dark,
      width,
      height,
      x,
      staffRows,
      spacing,
      verticalScore: verticalScore,
      rightSide: rightSide,
    )) {
      return true;
    }
  }
  return false;
}

bool _hasRepeatDots(
  Uint8List dark,
  int width,
  int height,
  int boundaryX,
  List<int> staffRows,
  int spacing, {
  required List<double> verticalScore,
  required bool rightSide,
}) {
  final bool hasRepeatBar = _hasBroadBarline(verticalScore, boundaryX, spacing);
  final List<List<int>> staves = <List<int>>[];
  for (int index = 0; index + 4 < staffRows.length;) {
    final List<int> group = staffRows.sublist(index, index + 5);
    final bool regular = <int>[0, 1, 2, 3].every((int gap) {
      final int difference = group[gap + 1] - group[gap];
      return difference >= spacing * 0.55 && difference <= spacing * 1.55;
    });
    if (regular) {
      staves.add(group);
      index += 5;
    } else {
      index++;
    }
  }
  if (staves.isEmpty) return false;

  // 진짜 도돌이표는 한 줄의 모든 보표에 찍힌다. 보표가 여럿인 총보에서
  // 한 보표만 보고 판정하면 조표의 ♯·♮나 겹세로선 옆 음표가 점처럼 보여
  // 오검출이 난다. 반대로 전부를 요구하면 점 바로 옆에 화음이 붙은 보표
  // 때문에 진짜를 놓친다. 그래서 보표가 셋 이상이면 두 보표가 맞으면 인정한다.
  final int needed = staves.length <= 2 ? 1 : 2;
  int matched = 0;
  final int near = math.max(2, (spacing * 0.45).round());
  final int far = math.max(near + 3, (spacing * 3.6).round());
  final int fromX = rightSide ? boundaryX + near : boundaryX - far;
  final int toX = rightSide ? boundaryX + far : boundaryX - near;
  for (final List<int> staff in staves) {
    final List<int> targetY = <int>[
      ((staff[1] + staff[2]) / 2).round(),
      ((staff[2] + staff[3]) / 2).round(),
    ];
    final List<({int x, int y})?> dots = <({int x, int y})?>[];
    for (final int y in targetY) {
      int? bestX;
      int? bestY;
      int bestInk = 0;
      for (int x = math.max(0, fromX); x <= math.min(width - 1, toX); x++) {
        for (int sampleCenterY = math.max(0, y - spacing ~/ 2);
            sampleCenterY <= math.min(height - 1, y + spacing ~/ 2);
            sampleCenterY++) {
          if (!_isCompactDot(
            dark,
            width,
            height,
            x,
            sampleCenterY,
            spacing,
          )) {
            continue;
          }
          int ink = 0;
          for (int dy = -math.max(1, spacing ~/ 3);
              dy <= math.max(1, spacing ~/ 3);
              dy++) {
            final int sampleY = (sampleCenterY + dy).clamp(0, height - 1);
            for (int dx = -1; dx <= 1; dx++) {
              final int sampleX = (x + dx).clamp(0, width - 1);
              ink += dark[sampleY * width + sampleX];
            }
          }
          if (ink > bestInk) {
            bestInk = ink;
            bestX = x;
            bestY = sampleCenterY;
          }
        }
      }
      dots.add(bestInk >= 3 && bestX != null && bestY != null
          ? (x: bestX, y: bestY)
          : null);
    }
    if (dots.length == 2 && dots[0] != null && dots[1] != null) {
      final int horizontalGap = (dots[0]!.x - dots[1]!.x).abs();
      final int verticalGap = (dots[0]!.y - dots[1]!.y).abs();
      if (horizontalGap <= spacing * 0.65 &&
          verticalGap >= spacing * 0.55 &&
          verticalGap <= spacing * 1.5 &&
          hasRepeatBar) {
        matched++;
        if (matched >= needed) return true;
      }
    }
  }
  return false;
}

bool _hasBroadBarline(
  List<double> verticalScore,
  int boundaryX,
  int spacing,
) {
  int runLeft = boundaryX;
  int runRight = boundaryX;
  while (runLeft > 0 && verticalScore[runLeft - 1] >= 0.42) {
    runLeft--;
  }
  while (runRight + 1 < verticalScore.length &&
      verticalScore[runRight + 1] >= 0.42) {
    runRight++;
  }
  return runRight - runLeft + 1 >= math.max(4, (spacing * 0.9).round());
}

bool _isCompactDot(
  Uint8List dark,
  int width,
  int height,
  int x,
  int y,
  int spacing,
) {
  if (dark[y * width + x] == 0) return false;
  int left = x;
  int right = x;
  int top = y;
  int bottom = y;
  while (left > 0 && dark[y * width + left - 1] != 0) {
    left--;
  }
  while (right + 1 < width && dark[y * width + right + 1] != 0) {
    right++;
  }
  while (top > 0 && dark[(top - 1) * width + x] != 0) {
    top--;
  }
  while (bottom + 1 < height && dark[(bottom + 1) * width + x] != 0) {
    bottom++;
  }
  final int blobWidth = right - left + 1;
  final int blobHeight = bottom - top + 1;
  final int maximum = math.max(4, (spacing * 1.2).round());
  return blobWidth >= 2 &&
      blobHeight >= 2 &&
      blobWidth <= maximum &&
      blobHeight <= maximum &&
      blobWidth <= blobHeight * 1.6 &&
      blobHeight <= blobWidth * 1.6;
}

int _staffSpacing(List<int> rows) {
  final Map<int, int> histogram = <int, int>{};
  for (int i = 0; i < rows.length - 1; i++) {
    final int difference = rows[i + 1] - rows[i];
    if (difference >= 3 && difference <= 24) {
      histogram[difference] = (histogram[difference] ?? 0) + 1;
    }
  }
  if (histogram.isEmpty) return 0;
  return histogram.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

/// 첫 줄의 윗선(마디 박스 위쪽). 첫 줄은 마디 번호가 인쇄되지 않아 y가
/// 짐작값이다. 그 값이 오선 안쪽이거나 너무 위(제목 쪽)면 오선 위 2칸으로 옮긴다.
double _lineTop(double y, int staffTop, int spacing, int height) {
  final double px = y * height;
  if (px <= staffTop - spacing * 0.5 && px >= staffTop - spacing * 4) return y;
  return ((staffTop - spacing * 2) / height).clamp(0.0, 1.0);
}

/// 이 줄의 오선에 걸친 굵은 세로선(보통 선의 2배 이상)의 x(픽셀).
/// 도돌이표(:‖, ‖:)와 끝세로줄의 굵은 선이다.
List<double> _thickLines(
  List<List<double>> lines,
  int width,
  int height,
  List<int> staffRows,
  int spacing,
) {
  final List<double> widths = <double>[for (final List<double> l in lines) l[3]]..sort();
  if (widths.isEmpty) return const <double>[];
  final double normal = widths[widths.length ~/ 2];
  // 마디선처럼 양 끝이 오선 맨 윗줄·맨 아랫줄에 맞아야 한다. 굵게 채워 그린
  // 음표 기둥 같은 것이 섞여 방향을 거꾸로 읽은 일이 있었다(Back to you 51마디).
  final List<List<int>> staves = _groupStaves(staffRows, spacing);
  if (staves.isEmpty) return const <double>[];
  final double tol = math.max(2.0, spacing * 0.3);
  bool near(double v, Iterable<int> targets) => targets.any((int t) => (v - t).abs() <= tol);
  return <double>[
    for (final List<double> l in lines)
      if (l[3] >= normal * 2 &&
          near(l[1] * height, staves.map((List<int> s) => s.first)) &&
          near(l[2] * height, staves.map((List<int> s) => s.last)))
        l[0] * width,
  ];
}

/// PDF 선 데이터에서 마디선 후보를 고른다.
///
/// 마디선은 오선 맨 윗줄에서 시작해 맨 아랫줄에서 끝난다(피아노처럼 여러
/// 보표에 걸치면 위 보표 맨 윗줄 ~ 아래 보표 맨 아랫줄). 음표 기둥은 길이가
/// 3.5칸이라 양 끝이 오선 줄과 맞지 않고, 괄호 갈고리는 오선 밖에 있다.
/// 점수는 마디선이 그어진 보표의 비율이다.
List<_LineCandidate> _vectorCandidates(
  List<List<double>> lines,
  int width,
  int height,
  List<int> staffRows,
  int spacing,
  _Run extent,
) {
  final List<List<int>> staves = _groupStaves(staffRows, spacing);
  if (staves.isEmpty) return const <_LineCandidate>[];
  final double tol = math.max(2.0, spacing * 0.3);
  final List<double> tops = <double>[for (final List<int> s in staves) s.first.toDouble()];
  final List<double> bottoms = <double>[for (final List<int> s in staves) s.last.toDouble()];
  bool near(double v, List<double> targets) => targets.any((double t) => (v - t).abs() <= tol);

  // 양 끝이 오선 줄에 맞는 세로선만 남긴다(픽셀 좌표).
  final List<(double, double, double)> bars = <(double, double, double)>[];
  for (final List<double> l in lines) {
    final double x = l[0] * width, top = l[1] * height, bottom = l[2] * height;
    if (x < extent.start - spacing || x > extent.end + spacing) continue;
    if (bottom < tops.first - tol || top > bottoms.last + tol) continue;
    if (!near(top, tops) || !near(bottom, bottoms)) continue;
    bars.add((x, top, bottom));
  }
  bars.sort((a, b) => a.$1.compareTo(b.$1));

  // 같은 x(±1.5px)의 선을 묶어, 그 자리에서 마디선이 그어진 보표 수를 센다.
  final List<_LineCandidate> out = <_LineCandidate>[];
  int i = 0;
  while (i < bars.length) {
    int j = i + 1;
    while (j < bars.length && bars[j].$1 - bars[j - 1].$1 <= 1.5) {
      j++;
    }
    final List<(double, double, double)> group = bars.sublist(i, j);
    int covered = 0;
    for (int s = 0; s < staves.length; s++) {
      if (group.any((b) => b.$2 <= tops[s] + tol && b.$3 >= bottoms[s] - tol)) covered++;
    }
    final double x = group.map((b) => b.$1).reduce((a, b) => a + b) / group.length;
    out.add(_LineCandidate(x.round(), covered / staves.length));
    i = j;
  }
  // 보표가 하나뿐인 줄은 시작에 세로선이 없다. 오선이 시작하는 곳을 시작선으로 둔다.
  if (!out.any((c) => (c.x - extent.start).abs() <= spacing * 1.5)) {
    out.insert(0, _LineCandidate(extent.start, 1));
  }
  // 끝선은 조표가 바뀌는 줄처럼 겹세로줄 뒤로 오선이 더 이어질 수 있어서,
  // 줄 끝 부근에 마디선이 하나도 없을 때만 오선 끝을 끝선으로 둔다.
  if (!out.any((c) => c.score >= 0.9 && c.x >= extent.end - extent.length * 0.12)) {
    out.add(_LineCandidate(extent.end, 1));
  }
  return out.where((c) => c.score >= 0.45).toList();
}

/// 마디선은 오선 맨 윗줄·맨 아랫줄에서 끝난다. 꼬리 묶음(빔)에 이어진 음표
/// 기둥은 오선 전체를 덮어도 바로 바깥까지 뻗어 나간다. 줄 안쪽 후보 중 바깥
/// 0.2~0.8칸이 거의 다 검으면 기둥으로 보고 점수를 깎는다. 1·2번 괄호의 갈고리는
/// 이보다 위에서 끝나고, 붙임줄·이음줄은 얇게 지나가서 걸리지 않는다.
double _beyondStaffFactor(
  Uint8List dark,
  int width,
  int top,
  int bottom,
  int spacing,
  int x,
  _Run extent,
) {
  // 줄 첫머리(음자리표·조표)와 끝선은 건드리지 않는다.
  if (x - extent.start <= extent.length * 0.12 || extent.end - x <= spacing) return 1;
  final int height = dark.length ~/ width;
  double coverage(int from, int to) {
    int covered = 0, total = 0;
    for (int y = math.max(0, from); y < math.min(height, to); y++) {
      total++;
      for (int dx = -1; dx <= 1; dx++) {
        if (dark[y * width + (x + dx).clamp(0, width - 1)] != 0) {
          covered++;
          break;
        }
      }
    }
    return total == 0 ? 0 : covered / total;
  }

  final int near = (spacing * 0.2).ceil(), far = (spacing * 0.8).ceil();
  final double above = coverage(top - far, top - near + 1);
  final double below = coverage(bottom + near, bottom + far + 1);
  return math.max(above, below) >= 0.75 ? 0.4 : 1;
}

/// 후보 선 중에서 마디 [count]개를 이루는 마디선 조합을 고른다.
///
/// 줄을 똑같이 나눈 자리 근처에서 찾으면, 조표가 긴 곡(샵 6개 등)처럼 첫
/// 마디가 넓을 때 진짜 마디선이 탈락한다. 그래서 '선 점수가 높고 마디 너비가
/// 고른' 조합을 통째로 고른다(동적 계획법). 첫 마디는 음자리표·조표 몫만큼
/// 넓어도 감점하지 않는다.
List<double>? _selectBoundaries(
  List<_LineCandidate> candidates,
  int count,
  int extentStart,
  int extentEnd,
) {
  final double average = (extentEnd - extentStart) / count;
  if (average <= 4 || candidates.isEmpty) return null;
  final List<_LineCandidate> c = <_LineCandidate>[...candidates]
    ..sort((a, b) => a.x.compareTo(b.x));
  final int n = c.length;
  double widthPenalty(int measure, double w) {
    final double r = w / average;
    if (measure == 0) {
      // 첫 마디: 머리(음자리표·조표) 때문에 평균의 0.8~2배까지는 자연스럽다.
      if (r >= 0.8 && r <= 2.0) return 0;
      final double edge = r < 0.8 ? 0.8 : 2.0;
      final double l = math.log(r / edge);
      return l * l;
    }
    final double l = math.log(r);
    return l * l;
  }

  const double negative = -1e9;
  // best[k][j]: k번째 마디선을 후보 j로 했을 때까지의 최고 점수.
  final List<List<double>> best =
      List<List<double>>.generate(count + 1, (_) => List<double>.filled(n, negative));
  final List<List<int>> from =
      List<List<int>>.generate(count + 1, (_) => List<int>.filled(n, -1));
  for (int j = 0; j < n; j++) {
    if ((c[j].x - extentStart).abs() <= average * 0.24) best[0][j] = c[j].score;
  }
  for (int k = 1; k <= count; k++) {
    for (int j = 0; j < n; j++) {
      for (int i = 0; i < j; i++) {
        if (best[k - 1][i] <= negative) continue;
        final double w = (c[j].x - c[i].x).toDouble();
        // 겹세로줄·도돌이 굵은 선 두 개를 각각 마디로 세지 않는다.
        if (w < average * 0.35 || w > average * 2.6) continue;
        final double v = best[k - 1][i] + c[j].score - widthPenalty(k - 1, w);
        if (v > best[k][j]) {
          best[k][j] = v;
          from[k][j] = i;
        }
      }
    }
  }
  int end = -1;
  for (int j = 0; j < n; j++) {
    if ((c[j].x - extentEnd).abs() > average * 0.24) continue;
    if (end < 0 || best[count][j] > best[count][end]) end = j;
  }
  if (end < 0 || best[count][end] <= negative) return null;
  final List<double> result = <double>[];
  double total = 0;
  for (int k = count, j = end; k >= 0; j = from[k][j], k--) {
    result.add(c[j].x.toDouble());
    total += c[j].score;
  }
  if (total / result.length < 0.58) return null;
  return result.reversed.toList();
}

/// 줄의 양 끝을 포함해 모든 보표를 관통하는 선(겹세로줄은 하나로)을 세서
/// 마디선 위치를 돌려준다. 줄 앞쪽의 괄호·음자리표 부근은 마디선으로 보지 않는다.
/// 양 끝이 안 잡히면 빈 목록.
List<double> _fullBarlines(
  List<_LineCandidate> candidates,
  int extentStart,
  int extentEnd,
  int spacing,
) {
  final int span = extentEnd - extentStart;
  final int merge = math.max(3, (spacing * 1.5).round());
  final List<int> lines = <int>[];
  for (final _LineCandidate c in candidates) {
    if (c.score < 0.9) continue;
    final bool atStart = (c.x - extentStart).abs() <= merge;
    if (!atStart && c.x < extentStart + span * 0.1) continue;
    if (lines.isNotEmpty && c.x - lines.last <= merge) continue;
    lines.add(c.x);
  }
  if (lines.length < 2) return const <double>[];
  if ((lines.first - extentStart).abs() > merge) return const <double>[];
  if ((extentEnd - lines.last).abs() > merge * 2) return const <double>[];
  return lines.map((int x) => x.toDouble()).toList();
}

List<_Run> _runsWhere(
  int start,
  int end,
  bool Function(int) test, {
  int bridge = 0,
}) {
  final List<_Run> runs = <_Run>[];
  int? runStart;
  int lastTrue = -1;
  for (int value = start; value < end; value++) {
    if (test(value)) {
      runStart ??= value;
      lastTrue = value;
    } else if (runStart != null && value - lastTrue > bridge) {
      runs.add(_Run(runStart, lastTrue));
      runStart = null;
    }
  }
  if (runStart != null) runs.add(_Run(runStart, lastTrue));
  return runs;
}

class _RowPeak {
  final int y;
  final int ink;
  const _RowPeak(this.y, this.ink);
}

class _Gap {
  final int top;
  final int bottom;
  const _Gap(this.top, this.bottom);
}

class _Run {
  final int start;
  final int end;
  const _Run(this.start, this.end);
  int get length => end - start + 1;
}

class _LineCandidate {
  final int x;
  final double score;
  const _LineCandidate(this.x, this.score);
}

class _PreparedPage {
  final int width;
  final int height;
  final Uint8List dark;

  const _PreparedPage(this.width, this.height, this.dark);

  factory _PreparedPage.fromImage(image_lib.Image source) {
    final image_lib.Image image =
        source.width > 800 ? image_lib.copyResize(source, width: 800) : source;
    final int width = image.width;
    final int height = image.height;
    final Uint8List dark = Uint8List(width * height);
    final Uint8List rgb = image.getBytes(order: image_lib.ChannelOrder.rgb);
    for (int pixel = 0, byte = 0; pixel < dark.length; pixel++, byte += 3) {
      final int luminance =
          rgb[byte] * 299 + rgb[byte + 1] * 587 + rgb[byte + 2] * 114;
      if (luminance < 170000) dark[pixel] = 1;
    }
    return _PreparedPage(width, height, dark);
  }
}
