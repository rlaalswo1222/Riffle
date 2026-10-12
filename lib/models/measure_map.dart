import 'score_anchor.dart';

class RepeatRegion {
  final int startMeasure;
  final int endMeasure;
  final int? firstEndingStart;
  final int? secondEndingStart;

  const RepeatRegion({
    required this.startMeasure,
    required this.endMeasure,
    this.firstEndingStart,
    this.secondEndingStart,
  });
}

class PlaybackBar {
  final int physicalMeasure;
  final int repeatPass;

  const PlaybackBar(this.physicalMeasure, {this.repeatPass = 0});
}

/// 악보를 실제로 연주하는 순서 위의 위치.
class PlaybackPosition {
  final double timeline;
  final double physicalMeasure;
  final int repeatPass;
  final int occurrence;
  final int occurrenceCount;

  const PlaybackPosition({
    required this.timeline,
    required this.physicalMeasure,
    required this.repeatPass,
    required this.occurrence,
    required this.occurrenceCount,
  });

  bool get isRepeated => occurrenceCount > 1 || repeatPass > 0;
}

/// 한 악보 위의 지점과 마디 번호를 서로 옮긴다.
///
/// 이 프로젝트에서 유일하게 어려운 부분이고, 나머지는 전부 이걸 나르는
/// 배관이다. 그래서 화면도 통신도 모르는 순수한 계산으로 떼어 뒀다.
///
///     내 악보의 이 점  →  measureAt()  →  37.4마디
///     37.4마디         →  bandOf()     →  네 악보의 이 줄
///
/// 서로 다른 PDF 가 이어지는 것은 가운데의 마디 번호가 같기 때문이다.
/// 좌표는 오갈 수 없다. 각자 악보가 다르므로 아무 뜻이 없다.
///
/// 먼저 줄 시작의 인쇄된 마디 번호로 각 줄의 마디 수를 구하고, 렌더링된
/// 악보 이미지에서 실제 세로 마디선을 찾는다. 이미지 검출에 실패한 줄만
/// 좌우 범위를 균등 분할해 동기화를 유지한다.
class MeasureMap {
  /// 읽는 순서(페이지, 그 다음 위에서 아래)로 정렬된 앵커.
  final List<ScoreAnchor> anchors;

  /// 도돌이표를 해석해 만든 반복 구간과 실제 연주 마디 배열.
  late final List<RepeatRegion> repeats;
  late final List<PlaybackBar> playbackBars;

  MeasureMap(List<ScoreAnchor> anchors)
      : anchors = List<ScoreAnchor>.unmodifiable(
          <ScoreAnchor>[...anchors]..sort(_readingOrder),
        ) {
    repeats =
        List<RepeatRegion>.unmodifiable(_deriveRepeatRegions(this.anchors));
    playbackBars = List<PlaybackBar>.unmodifiable(
        _buildPlaybackBars(this.anchors, repeats));
  }

  static int _readingOrder(ScoreAnchor a, ScoreAnchor b) {
    final int byPage = a.page.compareTo(b.page);
    return byPage != 0 ? byPage : a.y.compareTo(b.y);
  }

  bool get isEmpty => anchors.isEmpty;
  bool get isNotEmpty => anchors.isNotEmpty;
  int get length => anchors.length;
  int get playbackLength => playbackBars.length;
  bool get hasRepeats => repeats.isNotEmpty;

  /// 악보에서 누른 지점이 몇 마디인가.
  ///
  /// [x], [y] 는 페이지 안의 비율(0.0~1.0)이다.
  ///
  /// 앵커보다 위를 누르면 null 이다. 제목이나 여백을 눌렀을 때 아무
  /// 마디나 골라 보내면 다른 사람 화면이 엉뚱한 데로 튄다.
  double? measureAt(int page, double x, double y) {
    final int i = _lineAt(page, y);
    if (i < 0) return null;

    final ScoreAnchor line = anchors[i];
    final double span = _spanOf(i);
    if (span <= 0) {
      // 다음 줄이 없거나(마지막 줄) 번호가 거꾸로 붙었다. 줄 안에서
      // 어디를 눌렀는지 알 길이 없으니 줄의 시작으로 답한다.
      return line.measure;
    }
    final List<double>? boundaries = _boundariesOf(line, span);
    if (boundaries != null) {
      final double boundedX = x.clamp(boundaries.first, boundaries.last);
      int offset = boundaries.length - 2;
      for (int k = 0; k < boundaries.length - 1; k++) {
        if (boundedX < boundaries[k + 1]) {
          offset = k;
          break;
        }
      }
      final double left = boundaries[offset];
      final double right = boundaries[offset + 1];
      final double within = right > left
          ? ((boundedX - left) / (right - left)).clamp(0.0, 0.999999)
          : 0;
      return line.measure + offset + within;
    }
    final double width = line.xEnd - line.xStart;
    final double progress =
        width > 0 ? ((x - line.xStart) / width).clamp(0.0, 0.999999) : 0;
    return line.measure + progress * span;
  }

  /// 탭한 인쇄 마디가 연주 순서에서 나타나는 모든 위치를 돌려준다.
  ///
  /// 예를 들어 5~35마디를 반복하면 인쇄된 5마디는 연주 순서의
  /// 5번째와 36번째 두 위치를 가진다.
  List<PlaybackPosition> playbackPositionsAt(int page, double x, double y) {
    final double? physical = measureAt(page, x, y);
    if (physical == null || playbackBars.isEmpty) {
      return const <PlaybackPosition>[];
    }
    final int physicalBar = physical.floor();
    final double fraction = physical - physicalBar;
    final List<int> occurrences = <int>[];
    for (int i = 0; i < playbackBars.length; i++) {
      if (playbackBars[i].physicalMeasure == physicalBar) occurrences.add(i);
    }

    return <PlaybackPosition>[
      for (int i = 0; i < occurrences.length; i++)
        PlaybackPosition(
          timeline: occurrences[i] + fraction,
          physicalMeasure: physical,
          repeatPass: playbackBars[occurrences[i]].repeatPass,
          occurrence: i + 1,
          occurrenceCount: occurrences.length,
        ),
    ];
  }

  /// 탭 좌표를 단순 인쇄 마디가 아니라 반복 회차가 포함된 연주 순서로 바꾼다.
  /// 같은 반복 마디를 연속해서 누르면 다음 회차로 순환한다.
  PlaybackPosition? playbackPositionAt(
    int page,
    double x,
    double y, {
    double? currentTimeline,
  }) {
    final List<PlaybackPosition> positions = playbackPositionsAt(page, x, y);
    if (positions.isEmpty) return null;

    PlaybackPosition selected = positions.first;
    if (currentTimeline != null) {
      final int currentIndex =
          currentTimeline.floor().clamp(0, playbackBars.length - 1);
      final int physicalBar = selected.physicalMeasure.floor();
      final bool samePhysical =
          playbackBars[currentIndex].physicalMeasure == physicalBar;
      if (samePhysical && positions.length > 1) {
        selected = positions.firstWhere(
          (PlaybackPosition position) =>
              position.timeline.floor() > currentTimeline,
          orElse: () => positions.first,
        );
      } else {
        selected = positions.reduce(
          (PlaybackPosition a, PlaybackPosition b) =>
              (a.timeline - currentTimeline).abs() <=
                      (b.timeline - currentTimeline).abs()
                  ? a
                  : b,
        );
      }
    }
    return selected;
  }

  /// 공통 연주 순서 위치를 이 악보의 실제 인쇄 마디 위치로 바꾼다.
  MeasureBand? bandOfPlayback(double timeline) {
    if (timeline < 0 || playbackBars.isEmpty) return null;
    final int index = timeline.floor();
    if (index >= playbackBars.length) return null;
    final double fraction = timeline - index;
    return bandOf(playbackBars[index].physicalMeasure + fraction);
  }

  PlaybackBar? playbackBarAt(double timeline) {
    final int index = timeline.floor();
    return index >= 0 && index < playbackBars.length
        ? playbackBars[index]
        : null;
  }

  /// 그 마디가 이 악보의 어디인가.
  ///
  /// 마디 하나가 아니라 줄 전체를 돌려준다. 합주에서 "여기부터 다시" 는
  /// 원래 줄 단위로 오가는 말이고, 한 마디만 얇게 칠해 두면 태블릿을
  /// 세워놓고 보는 거리에서는 잘 안 보인다.
  MeasureBand? bandOf(double measure) {
    if (anchors.isEmpty) return null;
    if (measure < anchors.first.measure) return null;

    int i = anchors.length - 1;
    for (int k = 0; k < anchors.length - 1; k++) {
      if (anchors[k + 1].measure > measure) {
        i = k;
        break;
      }
    }

    final ScoreAnchor line = anchors[i];
    final ScoreAnchor? next = i + 1 < anchors.length ? anchors[i + 1] : null;
    final double span = _spanOf(i);
    final double progress =
        span > 0 ? ((measure - line.measure) / span).clamp(0.0, 0.999999) : 0;
    final int measureCount = span > 0 ? span.ceil() : 1;
    final double measureWidth = (line.xEnd - line.xStart) / measureCount;
    final int measureOffset = span > 0
        ? (measure - line.measure).floor().clamp(0, measureCount - 1).toInt()
        : 0;
    final List<double>? boundaries = _boundariesOf(line, span);
    final double left = boundaries != null
        ? boundaries[measureOffset]
        : line.xStart + measureOffset * measureWidth;
    final double right = boundaries != null
        ? boundaries[measureOffset + 1]
        : line.xStart + (measureOffset + 1) * measureWidth;
    final double withinMeasure = measure - measure.floorToDouble();

    return MeasureBand(
      page: line.page,
      top: line.y,
      // 다음 줄이 같은 페이지에 있으면 거기까지가 이 줄이다. 페이지가
      // 넘어가거나 마지막 줄이면 페이지 끝까지로 본다.
      bottom: line.systemBottom ??
          ((next != null && next.page == line.page) ? next.y : 1.0),
      x: boundaries != null
          ? left + withinMeasure * (right - left)
          : line.xStart + progress * (line.xEnd - line.xStart),
      left: left,
      right: right,
      startMeasure: line.measure,
      endMeasure: span > 0 ? line.measure + span : line.measure,
    );
  }

  /// 이 지점이 몇 번째 줄에 속하는가. 앵커보다 위면 -1.
  int _lineAt(int page, double y) {
    int found = -1;
    for (int i = 0; i < anchors.length; i++) {
      final ScoreAnchor a = anchors[i];
      if (a.page < page || (a.page == page && a.y <= y)) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  /// [i] 번째 줄에 들어 있는 마디 수. 알 수 없으면 0.
  double _spanOf(int i) {
    final ScoreAnchor current = anchors[i];
    final double? explicitEnd = current.endMeasure;
    final double span = explicitEnd != null
        ? explicitEnd - current.measure
        : i + 1 < anchors.length
            ? anchors[i + 1].measure - current.measure
            : 0;
    return span > 0 ? span : 0;
  }

  List<double>? _boundariesOf(ScoreAnchor anchor, double span) {
    final int measureCount = span.ceil();
    if (measureCount <= 0 || anchor.barlines.length != measureCount + 1) {
      return null;
    }
    for (int i = 1; i < anchor.barlines.length; i++) {
      if (anchor.barlines[i] <= anchor.barlines[i - 1]) return null;
    }
    return anchor.barlines;
  }

  static List<RepeatRegion> _deriveRepeatRegions(
    List<ScoreAnchor> anchors,
  ) {
    if (anchors.isEmpty) return const <RepeatRegion>[];
    final Set<int> starts = <int>{};
    final Set<int> ends = <int>{};
    final Set<int> firstEndings = <int>{};
    final Set<int> secondEndings = <int>{};
    for (final ScoreAnchor anchor in anchors) {
      final int count =
          ((anchor.endMeasure ?? anchor.measure) - anchor.measure).round();
      for (final int offset in anchor.repeatStarts) {
        if (offset >= 0 && offset <= count) {
          starts.add(anchor.measure.round() + offset);
        }
      }
      for (final int offset in anchor.repeatEnds) {
        if (offset >= 0 && offset <= count) {
          ends.add(anchor.measure.round() + offset);
        }
      }
      for (final int offset in anchor.firstEndings) {
        if (offset >= 0 && offset < count) {
          firstEndings.add(anchor.measure.round() + offset);
        }
      }
      for (final int offset in anchor.secondEndings) {
        if (offset >= 0 && offset < count) {
          secondEndings.add(anchor.measure.round() + offset);
        }
      }
    }
    // 2번 괄호가 X마디에 있으면 X마디 바로 앞에 반드시 도돌이 끝(:‖)이 있다.
    // 끝 기호를 이미지에서 놓쳐도 괄호 숫자는 텍스트라 확실하다.
    ends.addAll(secondEndings);
    // 2번 괄호 자리에서 새 반복이 시작될 수는 없다. 끝 기호(:‖)의 점이
    // 마디선 오른쪽으로 잡혀 시작으로 읽힌 경우다.
    starts.removeAll(secondEndings);
    if (ends.isEmpty) return const <RepeatRegion>[];

    final List<int> events = <int>{...starts, ...ends}.toList()..sort();
    final int firstMeasure = anchors.first.measure.floor();
    int? openStart;
    final List<RepeatRegion> regions = <RepeatRegion>[];

    for (final int measure in events) {
      // 같은 경계에서 반복 종료와 새 반복 시작이 함께 있으면 먼저 닫는다.
      if (ends.contains(measure)) {
        // 시작과 종료가 같은 내부 경계에 동시에 검출됐는데 앞선 시작표가
        // 없다면 박자표나 음표가 양쪽 도돌이표처럼 보인 경우가 대부분이다.
        // 실제 곡 처음부터의 반복 종료는 종료 방향만 검출된 경우에 한한다.
        final bool ambiguousImplicitStart =
            openStart == null && starts.contains(measure);
        final int start = openStart ?? firstMeasure;
        // 자동 인식에서 멀리 떨어진 음표 두 개를 잘못 짝짓지 않도록 일반적인
        // 도돌이 구간보다 지나치게 긴 후보는 버린다. 시작표가 있고 1·2번
        // 괄호까지 맞으면 긴 1번 괄호(먹이사슬 21~54마디)도 받아들인다.
        final bool endingBacked = openStart != null &&
            secondEndings.contains(measure) &&
            firstEndings.any((int value) => value > start && value < measure);
        if (!ambiguousImplicitStart &&
            measure - start >= 2 &&
            measure - start <= (endingBacked ? 64 : 32)) {
          final List<int> firstCandidates = firstEndings
              .where((int value) => value > start && value < measure)
              .toList()
            ..sort();
          final List<int> secondCandidates = secondEndings
              .where((int value) => value == measure)
              .toList()
            ..sort();
          regions.add(
            RepeatRegion(
              startMeasure: start,
              endMeasure: measure,
              firstEndingStart:
                  firstCandidates.isEmpty ? null : firstCandidates.first,
              secondEndingStart:
                  secondCandidates.isEmpty ? null : secondCandidates.first,
            ),
          );
        }
        openStart = null;
      }
      if (starts.contains(measure)) openStart ??= measure;
    }

    // 시작 도돌이표가 생략된 긴 반복은 보통 악보 처음으로 돌아간다.
    // 먼저 일반 길이 반복을 해석하고, 같은 2번 엔딩을 설명하는 정상 구간이
    // 없을 때만 `처음 → 2번 엔딩` 후보를 만든다. 따라서 5→36처럼 명시적인
    // 시작표가 있는 기존 짧은 반복은 이 보정에 덮어쓰이지 않는다.
    final List<int> orderedSecondEndings = secondEndings.toList()..sort();
    for (final int secondEnding in orderedSecondEndings) {
      final bool alreadyExplained = regions.any((RepeatRegion region) =>
          region.firstEndingStart != null &&
          region.endMeasure == secondEnding &&
          region.secondEndingStart == secondEnding);
      if (alreadyExplained ||
          !ends.contains(secondEnding) ||
          secondEnding - firstMeasure <= 32) {
        continue;
      }
      final List<int> firstCandidates = firstEndings
          .where((int value) =>
              value > firstMeasure &&
              value < secondEnding &&
              secondEnding - value <= 32)
          .toList()
        ..sort();
      if (firstCandidates.isEmpty) continue;
      regions.add(
        RepeatRegion(
          startMeasure: firstMeasure,
          endMeasure: secondEnding,
          firstEndingStart: firstCandidates.first,
          secondEndingStart: secondEnding,
        ),
      );
    }

    // 1·2번 엔딩이 확인된 반복이 시작표 없이 곡 처음부터로 잡혔는데, 1번
    // 엔딩 앞에 시작표가 있다면 그쪽이 진짜 시작이다. 그 시작표가 앞의
    // 가짜 종료표(겹세로선 옆 점음표 등)와 먼저 짝지어져 빠진 경우다.
    for (int i = 0; i < regions.length; i++) {
      final RepeatRegion region = regions[i];
      final int? first = region.firstEndingStart;
      if (first == null ||
          region.secondEndingStart != region.endMeasure ||
          region.startMeasure != firstMeasure ||
          starts.contains(firstMeasure)) {
        continue;
      }
      // 1번 엔딩보다 앞에서 끝나는 '엔딩 없는' 구간의 시작표만 후보다.
      // 짝을 못 찾고 남은 시작표(길이 제한으로 버려진 오검출 등)는 쓰지 않는다.
      final List<int> earlier = regions
          .where((RepeatRegion r) =>
              !identical(r, region) &&
              r.firstEndingStart == null &&
              r.startMeasure > firstMeasure &&
              r.endMeasure < first &&
              starts.contains(r.startMeasure) &&
              region.endMeasure - r.startMeasure <= 32)
          .map((RepeatRegion r) => r.startMeasure)
          .toList()
        ..sort();
      if (earlier.isEmpty) continue;
      regions[i] = RepeatRegion(
        startMeasure: earlier.last,
        endMeasure: region.endMeasure,
        firstEndingStart: first,
        secondEndingStart: region.secondEndingStart,
      );
    }

    final List<RepeatRegion> endingSupported = regions
        .where((RepeatRegion region) =>
            region.firstEndingStart != null &&
            region.secondEndingStart == region.endMeasure)
        .toList();
    if (endingSupported.isEmpty) {
      return regions..sort((a, b) => a.startMeasure.compareTo(b.startMeasure));
    }

    // 굵은 겹세로선이나 음표가 도돌이 점처럼 보이면 실제 반복 구간 바로
    // 앞·뒤 또는 내부에 가짜 구간이 붙을 수 있다. 1·2번 엔딩이 모두 확인된
    // 구간은 강한 증거이므로 그 구간과 겹치는 약한 후보를 제거한다.
    final List<RepeatRegion> filtered = regions.where((RepeatRegion region) {
      if (region.firstEndingStart != null &&
          region.secondEndingStart == region.endMeasure) {
        return true;
      }
      return !endingSupported.any((RepeatRegion supported) =>
          region.startMeasure < supported.endMeasure &&
          supported.startMeasure < region.endMeasure);
    }).toList()
      ..sort((a, b) => a.startMeasure.compareTo(b.startMeasure));
    final Set<String> seen = <String>{};
    return filtered
        .where(
            (region) => seen.add('${region.startMeasure}:${region.endMeasure}:'
                '${region.firstEndingStart}:${region.secondEndingStart}'))
        .toList();
  }

  static List<PlaybackBar> _buildPlaybackBars(
    List<ScoreAnchor> anchors,
    List<RepeatRegion> repeats,
  ) {
    if (anchors.isEmpty) return const <PlaybackBar>[];
    final int first = anchors.first.measure.floor();
    final int last = anchors
        .map((ScoreAnchor anchor) =>
            (anchor.endMeasure ?? anchor.measure).ceil())
        .reduce((int a, int b) => a > b ? a : b);
    final List<PlaybackBar> result = <PlaybackBar>[];
    int cursor = first;

    void append(int start, int end, {int pass = 0}) {
      for (int measure = start; measure < end && measure < last; measure++) {
        result.add(PlaybackBar(measure, repeatPass: pass));
      }
    }

    for (final RepeatRegion repeat in repeats) {
      if (repeat.startMeasure < cursor || repeat.endMeasure > last) continue;
      append(cursor, repeat.startMeasure);
      append(repeat.startMeasure, repeat.endMeasure, pass: 1);
      append(
        repeat.startMeasure,
        repeat.firstEndingStart ?? repeat.endMeasure,
        pass: 2,
      );
      cursor = repeat.endMeasure;
    }
    append(cursor, last);
    return _applyJump(anchors, repeats, result, first, last);
  }

  /// 이동 기호의 실제 마디. 세뇨·코다는 그 마디에서 시작하고,
  /// 나머지는 그 마디를 끝으로 이동하거나 멈춘다.
  static Map<String, int> _navigationMarks(List<ScoreAnchor> anchors) {
    final Map<String, int> marks = <String, int>{};
    for (final ScoreAnchor anchor in anchors) {
      final int count =
          ((anchor.endMeasure ?? anchor.measure) - anchor.measure).round();
      anchor.navigation.forEach((String kind, List<int> offsets) {
        final bool startsHere =
            kind == ScoreAnchor.segno || kind == ScoreAnchor.coda;
        for (final int offset in offsets) {
          if (offset < 0 || offset > count) continue;
          final int measure = anchor.measure.round() + offset - (startsHere ? 0 : 1);
          // 같은 기호가 여러 번 잡히면 세뇨·코다·Fine은 처음 것, 이동은 마지막 것.
          final bool keepLast =
              kind == ScoreAnchor.dalSegno || kind == ScoreAnchor.daCapo;
          if (!marks.containsKey(kind) || keepLast) marks[kind] = measure;
        }
      });
    }
    return marks;
  }

  /// D.S.·D.C.를 만나면 세뇨(또는 처음)로 돌아가 한 번 더 연주한다.
  /// 두 번째에는 도돌이를 다시 돌지 않고 1번 괄호를 건너뛰며,
  /// To Coda에서 코다로 뛰거나 Fine에서 멈춘다.
  static List<PlaybackBar> _applyJump(
    List<ScoreAnchor> anchors,
    List<RepeatRegion> repeats,
    List<PlaybackBar> base,
    int first,
    int last,
  ) {
    final Map<String, int> marks = _navigationMarks(anchors);
    final int? dalSegno = marks[ScoreAnchor.dalSegno];
    final int? jump = dalSegno ?? marks[ScoreAnchor.daCapo];
    if (jump == null) return base;
    final int? target = dalSegno != null ? marks[ScoreAnchor.segno] : first;
    if (target == null || target > jump) return base;
    final int at =
        base.lastIndexWhere((PlaybackBar bar) => bar.physicalMeasure == jump);
    if (at < 0) return base;

    final int? toCoda = marks[ScoreAnchor.toCoda];
    final int? fine = marks[ScoreAnchor.fine];
    // 코다 기호를 못 읽었으면 보통 D.S. 바로 다음 마디가 코다다.
    final int coda = marks[ScoreAnchor.coda] ?? jump + 1;
    final List<PlaybackBar> result = <PlaybackBar>[...base.take(at + 1)];
    int measure = target;
    while (measure < last) {
      final RepeatRegion? ending = repeats
          .where((RepeatRegion r) =>
              r.firstEndingStart != null &&
              measure >= r.firstEndingStart! &&
              measure < r.endMeasure)
          .firstOrNull;
      if (ending != null) {
        measure = ending.endMeasure;
        continue;
      }
      result.add(PlaybackBar(measure, repeatPass: 2));
      if (measure == fine) return result;
      if (measure == toCoda && coda > measure) {
        for (int m = coda; m < last; m++) {
          result.add(PlaybackBar(m));
        }
        return result;
      }
      // To Coda·Fine이 없으면 D.S. 자리를 지나 곡 끝까지 간다.
      measure++;
    }
    return result;
  }

  /// 이 페이지에 찍힌 앵커만.
  List<ScoreAnchor> onPage(int page) =>
      anchors.where((ScoreAnchor a) => a.page == page).toList();

  /// 다음 줄에 붙일 마디 번호를 미리 계산해 둔다.
  ///
  /// 줄마다 마디 수는 대개 같다. 앞의 간격을 그대로 이어 주면 사용자는
  /// 줄 시작만 두드리면 되고, 다른 곳만 고치면 된다. 한 페이지에 열 번
  /// 숫자를 치는 것과 열 번 두드리는 것의 차이다.
  ///
  /// [fallback] 은 아직 간격을 알 수 없을 때(앵커가 하나 이하) 쓴다.
  double nextMeasureGuess({double fallback = 4}) {
    if (anchors.isEmpty) return 1;
    final ScoreAnchor last = anchors.last;
    if (anchors.length == 1) return last.measure + fallback;
    final double gap = last.measure - anchors[anchors.length - 2].measure;
    return last.measure + (gap > 0 ? gap : fallback);
  }
}
