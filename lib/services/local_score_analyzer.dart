import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import 'score_pdf_document.dart';
import 'score_layout_detector.dart';

enum ScoreMatchDecision { accept, review, reject }

/// 서버나 고정 파일 해시 없이 디지털 PDF 악보를 분석한 결과.
class LocalScoreAnalysis {
  final String title;
  final String titleKey;
  final String artist;
  final String artistKey;
  final Set<String> contentFeatures;
  final List<int> printedMeasures;
  final MeasureMap map;
  final double analysisConfidence;
  final String? failureReason;

  const LocalScoreAnalysis({
    required this.title,
    required this.titleKey,
    required this.artist,
    required this.artistKey,
    required this.contentFeatures,
    required this.printedMeasures,
    required this.map,
    required this.analysisConfidence,
    this.failureReason,
  });

  bool get isUsable => failureReason == null && map.length >= 2;
  bool get hasRichContent => contentFeatures.length >= 40;
  double get lastMeasure => map.anchors.isEmpty
      ? 0
      : map.anchors.last.endMeasure ?? map.anchors.last.measure;
  int get playbackLength => map.playbackLength;

  LocalScoreAnalysis copyWith({MeasureMap? map}) => LocalScoreAnalysis(
        title: title,
        titleKey: titleKey,
        artist: artist,
        artistKey: artistKey,
        contentFeatures: contentFeatures,
        printedMeasures: printedMeasures,
        map: map ?? this.map,
        analysisConfidence: analysisConfidence,
        failureReason: failureReason,
      );
}

class ScoreMatchResult {
  final ScoreMatchDecision decision;
  final double confidence;
  final double titleSimilarity;
  final double artistSimilarity;
  final double contentSimilarity;
  final double structureSimilarity;
  final bool artistCompared;
  final bool contentCompared;
  final String reason;

  const ScoreMatchResult({
    required this.decision,
    required this.confidence,
    required this.titleSimilarity,
    required this.artistSimilarity,
    required this.contentSimilarity,
    required this.structureSimilarity,
    required this.artistCompared,
    required this.contentCompared,
    required this.reason,
  });

  bool get accepted => decision == ScoreMatchDecision.accept;
  bool get needsReview => decision == ScoreMatchDecision.review;
  bool get rejected => decision == ScoreMatchDecision.reject;
}

class LocalScoreAnalyzer {
  static final RegExp _integer = RegExp(r'^\s*(\d{1,4})\s*$');
  static final RegExp _term = RegExp(r'[가-힣]{2,}|[A-Za-z]{3,}');
  static final RegExp _titleCharacter = RegExp(r'[가-힣A-Za-z0-9\-–—]');
  static final RegExp _chord = RegExp(
    r'^[A-G](?:#|b)?(?:m|maj|min|dim|aug|sus|add)?\d*(?:/[A-G](?:#|b)?)?$',
    caseSensitive: false,
  );
  static final RegExp _version = RegExp(
    r'\b(?:lv|level)\s*\.?\s*\d+\b',
    caseSensitive: false,
  );

  static const Set<String> _sectionTerms = <String>{
    'intro',
    'verse',
    'chorus',
    'bridge',
    'interlude',
    'ending',
    'outro',
  };

  static const Set<String> _ignoredTerms = <String>{
    'guitar',
    'keyboard',
    'piano',
    'organ',
    'synth',
    'vocal',
    'voice',
    'drum',
    'drums',
    'bass',
    'electric',
    'acoustic',
    'tablature',
    'akbobada',
    'copyright',
    'music',
    'score',
    'page',
    '작사',
    '작곡',
    '노래',
    '수록곡',
  };

  Future<LocalScoreAnalysis> analyze(
    ScorePdfDocument document, {
    String? fileName,
  }) async {
    final List<ScorePdfPageText> pages = <ScorePdfPageText>[];
    for (int page = 0; page < document.pagesCount; page++) {
      pages.add(await document.extractPageText(page));
    }
    final LocalScoreAnalysis textAnalysis =
        analyzePages(pages, fileName: fileName);
    if (!textAnalysis.isUsable) return textAnalysis;
    try {
      final MeasureMap refined = await const ScoreLayoutDetector().refine(
        document,
        textAnalysis.map,
      );
      return textAnalysis.copyWith(
        map: markRepeatEndingsForTesting(refined, pages),
      );
    } catch (_) {
      // 이미지 분석이 실패해도 텍스트로 찾은 줄 단위 동기화는 유지한다.
      return textAnalysis;
    }
  }

  @visibleForTesting
  MeasureMap markRepeatEndingsForTesting(
    MeasureMap map,
    List<ScorePdfPageText> pages,
  ) {
    final RegExp ending = RegExp(r'^\s*([12])(?:\s*[.)])?\s*$');
    final List<_EndingLabel> candidates = <_EndingLabel>[];
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final ScorePdfPageText page = pages[pageIndex];
      final List<ScorePdfTextFragment> fragmentCandidates = page.fragments
          .where((fragment) => ending.hasMatch(fragment.text))
          .toList();
      for (final ScorePdfTextFragment fragment in fragmentCandidates) {
        final bool punctuated =
            fragment.text.contains('.') || fragment.text.contains(')');
        final int sameRow = fragmentCandidates
            .where((other) => (other.centerY - fragment.centerY).abs() <= 0.008)
            .length;
        // 기타 타브에는 같은 높이에 1·2 같은 숫자가 여러 개 이어진다.
        // 엔딩 번호는 같은 줄에 홀로 놓이므로, 문장부호 없는 밀집 숫자열은
        // 후보 단계에서 제외한다.
        if (!punctuated && sameRow >= 3) continue;
        candidates.add(_EndingLabel(pageIndex, fragment));
      }
      for (final ScorePdfTextFragment digit in page.characters) {
        if (digit.text != '1' && digit.text != '2') continue;
        for (final ScorePdfTextFragment punctuation in page.characters) {
          if (punctuation.text != '.' && punctuation.text != ')') continue;
          if ((punctuation.centerY - digit.centerY).abs() > 0.006 ||
              punctuation.left < digit.right - 0.002 ||
              punctuation.left - digit.right > 0.012) {
            continue;
          }
          // "(2024.04)"처럼 사이에 다른 글자가 있으면 엔딩 번호가 아니다.
          final bool separated = page.characters.any((other) =>
              !identical(other, digit) &&
              !identical(other, punctuation) &&
              other.text.trim().isNotEmpty &&
              (other.centerY - digit.centerY).abs() <= 0.006 &&
              other.centerX > digit.right - 0.001 &&
              other.centerX < punctuation.left + 0.001);
          if (separated) continue;
          candidates.add(
            _EndingLabel(
              pageIndex,
              ScorePdfTextFragment(
                text: '${digit.text}${punctuation.text}',
                left: digit.left,
                top: math.min(digit.top, punctuation.top),
                right: punctuation.right,
                bottom: math.max(digit.bottom, punctuation.bottom),
              ),
            ),
          );
        }
      }
    }

    final List<ScoreAnchor> anchors = <ScoreAnchor>[...map.anchors];
    final List<({int number, int anchor, int offset, int physical})> located =
        <({int number, int anchor, int offset, int physical})>[];
    for (final _EndingLabel candidate in candidates) {
      final int pageIndex = candidate.page;
      final ScorePdfTextFragment label = candidate.fragment;
      final Match? match = ending.firstMatch(label.text);
      if (match == null) continue;
      final int number = int.parse(match.group(1)!);
      int bestAnchor = -1;
      double bestDistance = double.infinity;
      for (int index = 0; index < anchors.length; index++) {
        final ScoreAnchor anchor = anchors[index];
        if (anchor.page != pageIndex) continue;
        final double systemWidth = anchor.xEnd - anchor.xStart;
        final double leftInset = math.min(0.040, systemWidth * 0.035);
        if (label.centerY < anchor.y - 0.080 ||
            label.centerY > anchor.y + 0.020 ||
            label.centerX < anchor.xStart + leftInset ||
            label.centerX > anchor.xEnd) {
          continue;
        }
        final double distance = (label.centerY - anchor.y).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          bestAnchor = index;
        }
      }
      if (bestAnchor < 0) continue;
      final ScoreAnchor anchor = anchors[bestAnchor];
      final List<double> lines = _measureLines(anchor);
      int offset = lines.length - 2;
      for (int index = 0; index < lines.length - 1; index++) {
        if (label.centerX < lines[index + 1]) {
          offset = index;
          break;
        }
      }
      final int physical = anchor.measure.round() + offset;
      located.add((
        number: number,
        anchor: bestAnchor,
        offset: offset,
        physical: physical,
      ));
    }

    final Set<int> firstPositions = located
        .where((item) => item.number == 1)
        .map((item) => item.physical)
        .toSet();
    final Set<int> secondPositions = located
        .where((item) => item.number == 2)
        .map((item) => item.physical)
        .toSet();
    final Set<int> ambiguous = firstPositions.intersection(secondPositions);
    for (final item in located) {
      if (ambiguous.contains(item.physical)) continue;
      final ScoreAnchor anchor = anchors[item.anchor];
      if (item.number == 1 && !anchor.firstEndings.contains(item.offset)) {
        anchors[item.anchor] = anchor.copyWith(
          firstEndings: <int>[...anchor.firstEndings, item.offset],
        );
      } else if (item.number == 2 &&
          !anchor.secondEndings.contains(item.offset)) {
        anchors[item.anchor] = anchor.copyWith(
          secondEndings: <int>[...anchor.secondEndings, item.offset],
        );
      }
    }
    _markNavigation(anchors, pages);
    return MeasureMap(anchors);
  }

  /// 줄의 마디선. 못 찾은 줄은 마디 수로 균등하게 나눠 본다.
  static List<double> _measureLines(ScoreAnchor anchor) {
    if (anchor.barlines.length >= 2) return anchor.barlines;
    final int measures = math.max(
        1, ((anchor.endMeasure ?? anchor.measure + 4) - anchor.measure).round());
    return <double>[
      for (int k = 0; k <= measures; k++)
        anchor.xStart + (anchor.xEnd - anchor.xStart) * k / measures,
    ];
  }

  // 악보 폰트(Maestro 등)는 세뇨를 '%', 코다를 'Þ' 자리에 둔다.
  static const Set<String> _segnoGlyphs = <String>{'%', '\uF025', '\u{1D10B}'};
  static const Set<String> _codaGlyphs = <String>{'\uF0DE', '\u00DE', '\u{1D10C}'};
  static final RegExp _dalSegno =
      RegExp(r'^(?:D\.\s?S\.|Dal\s+Segno)', caseSensitive: false);
  static final RegExp _daCapo =
      RegExp(r'^(?:D\.\s?C\.|Da\s+Capo)', caseSensitive: false);

  /// 텍스트로 찍힌 세뇨·코다 기호와 D.S.·D.C.·To Coda·Fine 지시를 찾아
  /// 해당 줄의 마디 경계에 붙인다. 실제 이동은 [MeasureMap]이 계산한다.
  void _markNavigation(
    List<ScoreAnchor> anchors,
    List<ScorePdfPageText> pages,
  ) {
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final List<ScorePdfTextFragment> fragments = pages[pageIndex].fragments;
      for (final ScorePdfTextFragment fragment in fragments) {
        final String text = fragment.text.trim();
        // 같은 높이에서 바로 왼쪽에 붙은 글자(예: "To", "D.S. al").
        final String before = fragments
            .where((other) =>
                !identical(other, fragment) &&
                (other.centerY - fragment.centerY).abs() <= 0.008 &&
                other.right <= fragment.left + 0.004 &&
                fragment.left - other.right <= 0.04)
            .map((other) => other.text.trim())
            .join(' ');
        final String? kind;
        if (_segnoGlyphs.contains(text)) {
          kind = ScoreAnchor.segno;
        } else if (_codaGlyphs.contains(text) ||
            RegExp(r'^(?:To\s+)?Coda$').hasMatch(text)) {
          if (text.startsWith('To') || RegExp(r'To$').hasMatch(before)) {
            kind = ScoreAnchor.toCoda;
          } else if (_dalSegno.hasMatch(before) ||
              _daCapo.hasMatch(before) ||
              RegExp(r'al$').hasMatch(before)) {
            kind = null; // "D.S. al Coda"의 일부
          } else {
            kind = ScoreAnchor.coda;
          }
        } else if (_dalSegno.hasMatch(text)) {
          kind = ScoreAnchor.dalSegno;
        } else if (_daCapo.hasMatch(text)) {
          kind = ScoreAnchor.daCapo;
        } else if (text == 'Fine') {
          kind = ScoreAnchor.fine;
        } else {
          kind = null;
        }
        if (kind == null) continue;

        // 기호는 줄 위나 아래에 찍힌다. 그 높이까지 내려온 마지막 줄에 붙인다.
        int index = -1;
        for (int i = 0; i < anchors.length; i++) {
          if (anchors[i].page == pageIndex &&
              anchors[i].y - 0.04 <= fragment.centerY &&
              (index < 0 || anchors[i].y > anchors[index].y)) {
            index = i;
          }
        }
        if (index < 0) continue;
        final ScoreAnchor anchor = anchors[index];
        final List<double> lines = _measureLines(anchor);
        final double x = fragment.centerX;
        int measure = lines.length - 2;
        for (int k = 0; k < lines.length - 1; k++) {
          if (x < lines[k + 1]) {
            measure = k;
            break;
          }
        }
        final bool startsHere =
            kind == ScoreAnchor.segno || kind == ScoreAnchor.coda;
        int boundary = measure;
        if (!startsHere) {
          // 끝 지시는 마디 끝에 붙인다. 마디 맨 앞에 찍혔으면 앞 마디의 끝이다.
          final double width = lines[measure + 1] - lines[measure];
          final double within = width > 0 ? (x - lines[measure]) / width : 1;
          boundary = within < 0.25 && measure > 0 ? measure : measure + 1;
        }
        final Map<String, List<int>> navigation = <String, List<int>>{
          ...anchor.navigation,
          kind: <int>{...?anchor.navigation[kind], boundary}.toList()..sort(),
        };
        anchors[index] = anchor.copyWith(navigation: navigation);
      }
    }
  }

  /// 테스트와 플랫폼별 PDF 어댑터가 함께 쓰는 순수 분석 진입점.
  LocalScoreAnalysis analyzePages(
    List<ScorePdfPageText> pages, {
    String? fileName,
  }) {
    if (pages.isEmpty || pages.every((page) => page.fullText.trim().isEmpty)) {
      return _failure('PDF에서 제목과 마디 번호를 읽지 못했습니다.');
    }

    final _Title title = _extractTitle(pages.first, fileName: fileName);
    final Set<String> content = _contentFeatures(pages);
    final List<_MeasureLabel> labels = _measureLabels(pages);
    final MeasureMap map = _buildMap(labels);

    if (labels.length < 2 || map.length < 3) {
      return _analysis(
        title: title,
        content: content,
        labels: labels,
        map: map,
        failureReason: '줄마다 표시된 마디 번호를 충분히 찾지 못했습니다.',
      );
    }
    if (title.key.length < 2 && content.length < 8) {
      return _analysis(
        title: title,
        content: content,
        labels: labels,
        map: map,
        failureReason: '곡을 구분할 제목·가사·코드 정보를 충분히 찾지 못했습니다.',
      );
    }

    final double labelEvidence = (labels.length / 8).clamp(0.0, 1.0);
    final double identityEvidence = ((title.key.isNotEmpty ? 0.65 : 0) +
            (content.length / 40).clamp(0.0, 0.35))
        .clamp(0.0, 1.0);
    return _analysis(
      title: title,
      content: content,
      labels: labels,
      map: map,
      confidence: 0.55 * labelEvidence + 0.45 * identityEvidence,
    );
  }

  ScoreMatchResult compare(
    LocalScoreAnalysis reference,
    LocalScoreAnalysis candidate,
  ) {
    if (!candidate.isUsable) {
      return ScoreMatchResult(
        decision: ScoreMatchDecision.reject,
        confidence: 0,
        titleSimilarity: 0,
        artistSimilarity: 0,
        contentSimilarity: 0,
        structureSimilarity: 0,
        artistCompared: false,
        contentCompared: false,
        reason: candidate.failureReason ?? '악보를 분석하지 못했습니다.',
      );
    }

    final double titleSimilarity =
        _dice(reference.titleKey, candidate.titleKey);
    final bool artistCompared =
        reference.artistKey.isNotEmpty && candidate.artistKey.isNotEmpty;
    final double artistSimilarity =
        artistCompared ? _dice(reference.artistKey, candidate.artistKey) : 0;
    final bool contentCompared =
        reference.hasRichContent && candidate.hasRichContent;
    final double contentSimilarity = contentCompared
        ? _jaccard(reference.contentFeatures, candidate.contentFeatures)
        : 0;
    final double structureSimilarity = _structureSimilarity(
      reference,
      candidate,
    );

    // 비교할 수 없는 자료는 0점으로 벌주지 않고 가중치 자체를 뺀다.
    double weighted = 0.55 * titleSimilarity + 0.25 * structureSimilarity;
    double weight = 0.80;
    if (artistCompared) {
      weighted += 0.10 * artistSimilarity;
      weight += 0.10;
    }
    if (contentCompared) {
      weighted += 0.20 * contentSimilarity;
      weight += 0.20;
    }
    final double confidence = (weighted / weight).clamp(0.0, 1.0);

    final bool artistCompatible = !artistCompared || artistSimilarity >= 0.65;
    final bool strongTitle = titleSimilarity >= 0.86 && artistCompatible;
    final bool strongContent = contentCompared &&
        contentSimilarity >= 0.48 &&
        structureSimilarity >= 0.55;
    final bool conflictingIdentity = titleSimilarity < 0.35 &&
        ((artistCompared && artistSimilarity < 0.35) ||
            (contentCompared && contentSimilarity < 0.12));

    final ScoreMatchDecision decision;
    final String reason;
    if ((strongTitle && structureSimilarity >= 0.45) ||
        (strongContent && confidence >= 0.60)) {
      decision = ScoreMatchDecision.accept;
      reason = '같은 곡이며 마디 구조도 연결 가능한 것으로 판단했습니다.';
    } else if (conflictingIdentity ||
        (titleSimilarity < 0.20 && structureSimilarity < 0.55)) {
      decision = ScoreMatchDecision.reject;
      reason = '제목과 음악 구조가 기준 악보와 다릅니다.';
    } else {
      decision = ScoreMatchDecision.review;
      reason = '같은 곡일 가능성은 있지만 편곡 구조를 자동으로 확정하기 어렵습니다.';
    }

    return ScoreMatchResult(
      decision: decision,
      confidence: confidence,
      titleSimilarity: titleSimilarity,
      artistSimilarity: artistSimilarity,
      contentSimilarity: contentSimilarity,
      structureSimilarity: structureSimilarity,
      artistCompared: artistCompared,
      contentCompared: contentCompared,
      reason: reason,
    );
  }

  /// 여러 파트의 연주 길이가 가장 잘 맞도록, 도돌이표를 실제로 펼쳐 쓴
  /// 악보에서는 영상 오검출로 생긴 반복을 사용하지 않는다.
  ///
  /// 각 악보는 `검출된 반복 사용`과 `인쇄된 순서 그대로` 두 후보를 가지며,
  /// 전체 연주 마디 수의 차이가 가장 작은 조합을 고른다. 두 조합이 같으면
  /// 검출 결과를 보존하므로 모든 파트에 같은 도돌이표가 있는 곡도 유지된다.
  List<LocalScoreAnalysis> alignPlaybackTimelines(
    List<LocalScoreAnalysis> analyses,
  ) {
    if (analyses.length < 2) return List<LocalScoreAnalysis>.of(analyses);
    final List<List<LocalScoreAnalysis>> variants = analyses.map((analysis) {
      if (!analysis.map.hasRepeats) return <LocalScoreAnalysis>[analysis];
      final List<RepeatRegion> endingSupported = analysis.map.repeats
          .where((repeat) =>
              repeat.firstEndingStart != null &&
              repeat.secondEndingStart == repeat.endMeasure)
          .toList(growable: false);
      final MeasureMap printed = MeasureMap(
        analysis.map.anchors
            .map((ScoreAnchor anchor) => anchor.copyWith(
                  repeatStarts: const <int>[],
                  repeatEnds: const <int>[],
                  firstEndings: const <int>[],
                  secondEndings: const <int>[],
                ))
            .toList(growable: false),
      );
      final List<LocalScoreAnalysis> result = <LocalScoreAnalysis>[analysis];
      if (endingSupported.isNotEmpty &&
          endingSupported.length < analysis.map.repeats.length) {
        final MeasureMap supportedOnly =
            _mapWithRepeatRegions(analysis.map, endingSupported);
        if (supportedOnly.hasRepeats) {
          result.add(analysis.copyWith(map: supportedOnly));
        }
      }
      result.add(analysis.copyWith(map: printed));
      return result;
    }).toList(growable: false);

    List<LocalScoreAnalysis> best = analyses;
    double bestCost = double.infinity;
    void evaluate(List<LocalScoreAnalysis> choice, int changed) {
      final List<int> lengths =
          choice.map((analysis) => analysis.playbackLength).toList();
      final int shortest = lengths.reduce(math.min);
      final int longest = lengths.reduce(math.max);
      final double cost =
          (longest - shortest) / math.max(1, longest) + changed * 0.0001;
      if (cost < bestCost) {
        bestCost = cost;
        best = List<LocalScoreAnalysis>.of(choice);
      }
    }

    void visit(
      int scoreIndex,
      List<LocalScoreAnalysis> choice,
      int changed,
    ) {
      if (scoreIndex == variants.length) {
        evaluate(choice, changed);
        return;
      }
      for (int variantIndex = 0;
          variantIndex < variants[scoreIndex].length;
          variantIndex++) {
        choice.add(variants[scoreIndex][variantIndex]);
        visit(scoreIndex + 1, choice, changed + variantIndex);
        choice.removeLast();
      }
    }

    visit(0, <LocalScoreAnalysis>[], 0);
    return best;
  }

  MeasureMap _mapWithRepeatRegions(
    MeasureMap source,
    List<RepeatRegion> regions,
  ) {
    final List<ScoreAnchor> cleared = source.anchors
        .map((anchor) => anchor.copyWith(
              repeatStarts: const <int>[],
              repeatEnds: const <int>[],
              firstEndings: const <int>[],
              secondEndings: const <int>[],
            ))
        .toList(growable: false);
    final List<List<int>> starts =
        List<List<int>>.generate(cleared.length, (_) => <int>[]);
    final List<List<int>> ends =
        List<List<int>>.generate(cleared.length, (_) => <int>[]);
    final List<List<int>> firstEndings =
        List<List<int>>.generate(cleared.length, (_) => <int>[]);
    final List<List<int>> secondEndings =
        List<List<int>>.generate(cleared.length, (_) => <int>[]);

    void place(
      int measure,
      List<List<int>> target, {
      required bool ending,
      required bool preferStart,
    }) {
      int bestIndex = -1;
      int bestOffset = -1;
      int bestPriority = 3;
      for (int index = 0; index < cleared.length; index++) {
        final ScoreAnchor anchor = cleared[index];
        final int count =
            ((anchor.endMeasure ?? anchor.measure) - anchor.measure).round();
        final int offset = measure - anchor.measure.round();
        if (offset < 0 || offset > count || (ending && offset >= count)) {
          continue;
        }
        final int priority =
            preferStart ? (offset == 0 ? 0 : 1) : (offset == count ? 0 : 1);
        if (priority < bestPriority) {
          bestPriority = priority;
          bestIndex = index;
          bestOffset = offset;
        }
      }
      if (bestIndex >= 0 && !target[bestIndex].contains(bestOffset)) {
        target[bestIndex].add(bestOffset);
      }
    }

    for (final RepeatRegion region in regions) {
      place(region.startMeasure, starts, ending: false, preferStart: true);
      place(region.endMeasure, ends, ending: false, preferStart: false);
      final int? first = region.firstEndingStart;
      if (first != null) {
        place(first, firstEndings, ending: true, preferStart: true);
      }
      final int? second = region.secondEndingStart;
      if (second != null) {
        place(second, secondEndings, ending: true, preferStart: true);
      }
    }

    return MeasureMap(<ScoreAnchor>[
      for (int index = 0; index < cleared.length; index++)
        cleared[index].copyWith(
          repeatStarts: starts[index]..sort(),
          repeatEnds: ends[index]..sort(),
          firstEndings: firstEndings[index]..sort(),
          secondEndings: secondEndings[index]..sort(),
        ),
    ]);
  }

  LocalScoreAnalysis _analysis({
    required _Title title,
    required Set<String> content,
    required List<_MeasureLabel> labels,
    required MeasureMap map,
    double confidence = 0,
    String? failureReason,
  }) =>
      LocalScoreAnalysis(
        title: title.display,
        titleKey: title.key,
        artist: title.artist,
        artistKey: title.artistKey,
        contentFeatures: content,
        printedMeasures: labels.map((label) => label.measure).toList(),
        map: map,
        analysisConfidence: confidence,
        failureReason: failureReason,
      );

  LocalScoreAnalysis _failure(String reason) => LocalScoreAnalysis(
        title: '',
        titleKey: '',
        artist: '',
        artistKey: '',
        contentFeatures: const <String>{},
        printedMeasures: const <int>[],
        map: MeasureMap(const <ScoreAnchor>[]),
        analysisConfidence: 0,
        failureReason: reason,
      );

  _Title _extractTitle(ScorePdfPageText page, {String? fileName}) {
    final List<ScorePdfTextFragment> candidates =
        page.fragments.where((fragment) {
      final double height = fragment.bottom - fragment.top;
      return fragment.top < 0.11 &&
          height >= 0.017 &&
          _titleCharacter.hasMatch(fragment.text);
    }).toList();

    final List<_TextLine> lines = <_TextLine>[];
    for (final ScorePdfTextFragment fragment in candidates) {
      _TextLine? line;
      for (final _TextLine candidate in lines) {
        if ((candidate.centerY - fragment.centerY).abs() <= 0.012) {
          line = candidate;
          break;
        }
      }
      (line ??= _TextLine()).add(fragment);
      if (!lines.contains(line)) lines.add(line);
    }
    lines.sort((a, b) => b.score.compareTo(a.score));

    String raw = lines.isEmpty ? '' : lines.first.text;
    if (raw.isEmpty && fileName != null) {
      raw = fileName.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
    }
    raw = raw.replaceAll('_', ' ').trim();

    String artist = '';
    String title = raw;
    final Match? separated =
        RegExp(r'^(.{2,30}?)\s*[-–—]\s*(.+)$').firstMatch(raw);
    if (separated != null) {
      artist = separated.group(1)!.trim();
      title = separated.group(2)!.trim();
    }
    if (artist.isEmpty) artist = _artistFromMetadata(page.fullText);

    title = title
        .replaceAll(_version, ' ')
        .replaceAll(
          RegExp(
            r'\b(?:guitar|keyboard|piano|organ|synth|drums?|bass|vocal)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return _Title(
      display: title,
      key: _identityKey(title),
      artist: artist,
      artistKey: _artistKey(artist),
    );
  }

  String _artistFromMetadata(String fullText) {
    final List<String> lines = fullText
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    for (int i = 0; i + 1 < lines.length; i++) {
      if (!RegExp(r'^(?:작사|작곡|노래|artist)$', caseSensitive: false)
          .hasMatch(lines[i + 1])) {
        continue;
      }
      final String candidate = lines[i];
      final Match? korean = RegExp(r'\(([가-힣]{2,})\)').firstMatch(candidate);
      return korean?.group(1) ?? candidate;
    }
    final Match? inline = RegExp(
      r'([A-Za-z가-힣]{2,}(?:\([가-힣]{2,}\))?)\s*(?:작사|작곡|노래)',
    ).firstMatch(fullText);
    if (inline != null) {
      final String candidate = inline.group(1)!;
      final Match? korean = RegExp(r'\(([가-힣]{2,})\)').firstMatch(candidate);
      return korean?.group(1) ?? candidate;
    }
    return '';
  }

  Set<String> _contentFeatures(List<ScorePdfPageText> pages) {
    final Set<String> features = <String>{};
    final StringBuffer hangul = StringBuffer();
    for (final ScorePdfPageText page in pages) {
      for (final Match match in _term.allMatches(page.fullText)) {
        final String term = match.group(0)!.toLowerCase();
        if (_ignoredTerms.contains(term)) continue;
        features.add('word:$term');
        if (RegExp(r'^[가-힣]+$').hasMatch(term)) hangul.write(term);
      }

      final List<String> tokens = page.fullText.split(RegExp(r'\s+'));
      for (int index = 0; index < tokens.length; index++) {
        final String token =
            tokens[index].replaceAll(RegExp(r'[^A-Ga-g#bmjinsud/0-9]'), '');
        final String previous = index == 0
            ? ''
            : tokens[index - 1]
                .replaceAll(RegExp(r'[^A-Za-z]'), '')
                .toLowerCase();
        if (_chord.hasMatch(token) && !_sectionTerms.contains(previous)) {
          features.add('chord:${token.toUpperCase()}');
        }
      }
    }

    final String lyric = hangul.toString();
    for (int i = 0; i + 1 < lyric.length; i++) {
      features.add('lyric:${lyric.substring(i, i + 2)}');
    }
    return features;
  }

  List<_MeasureLabel> _measureLabels(List<ScorePdfPageText> pages) {
    final List<_MeasureLabel> candidates = <_MeasureLabel>[];
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final ScorePdfPageText page = pages[pageIndex];
      final List<ScorePdfTextFragment> numbers = page.characters.isNotEmpty
          ? _numbersFromCharacters(page.characters)
          : page.fragments;
      for (final ScorePdfTextFragment fragment in numbers) {
        final Match? match = _integer.firstMatch(fragment.text);
        final double height = fragment.bottom - fragment.top;
        if (match == null ||
            fragment.left > 0.125 ||
            height < 0.0045 ||
            height > 0.04) {
          continue;
        }
        final int value = int.parse(match.group(1)!);
        // 1~2는 Gt. 1/2나 페이지 번호와 충돌하기 쉬워 첫 마디를 별도로 복원한다.
        if (value < 3 || value > 2000) continue;
        final _MeasureLabel label = _MeasureLabel(
          page: pageIndex,
          y: (fragment.top - 0.008).clamp(0.0, 0.98),
          x: fragment.left,
          measure: value,
        );
        final bool duplicate = candidates.any((candidate) =>
            candidate.page == label.page &&
            candidate.measure == label.measure &&
            (candidate.y - label.y).abs() < 0.01);
        if (!duplicate) candidates.add(label);
      }
    }
    candidates.sort(_MeasureLabel.readingOrder);
    if (candidates.isEmpty) return const <_MeasureLabel>[];

    // 왼쪽 마디 번호는 페이지를 넘어서 증가한다. TAB·템포·페이지 숫자는
    // 이 성질을 오래 유지하지 못하므로 가장 긴 증가열에서 빠진다.
    final List<int> length = List<int>.filled(candidates.length, 1);
    final List<int> previous = List<int>.filled(candidates.length, -1);
    int best = 0;
    for (int i = 0; i < candidates.length; i++) {
      for (int j = 0; j < i; j++) {
        final int gap = candidates[i].measure - candidates[j].measure;
        if (gap <= 0 || gap > 64) continue;
        if ((candidates[i].x - candidates[j].x).abs() > 0.035) continue;
        if (length[j] + 1 > length[i]) {
          length[i] = length[j] + 1;
          previous[i] = j;
        }
      }
      if (length[i] > length[best]) best = i;
    }

    final List<_MeasureLabel> result = <_MeasureLabel>[];
    for (int at = best; at >= 0; at = previous[at]) {
      result.add(candidates[at]);
      if (previous[at] < 0) break;
    }
    return result.reversed.toList(growable: false);
  }

  List<ScorePdfTextFragment> _numbersFromCharacters(
    List<ScorePdfTextFragment> characters,
  ) {
    final List<ScorePdfTextFragment> digits = characters
        .where((character) =>
            RegExp(r'^\d$').hasMatch(character.text) && character.left <= 0.125)
        .toList()
      ..sort((a, b) {
        final int byY = a.centerY.compareTo(b.centerY);
        return byY != 0 ? byY : a.left.compareTo(b.left);
      });
    final List<List<ScorePdfTextFragment>> rows =
        <List<ScorePdfTextFragment>>[];
    for (final ScorePdfTextFragment digit in digits) {
      List<ScorePdfTextFragment>? row;
      for (final List<ScorePdfTextFragment> candidate in rows) {
        final double center =
            candidate.map((item) => item.centerY).reduce((a, b) => a + b) /
                candidate.length;
        if ((center - digit.centerY).abs() <= 0.0045) {
          row = candidate;
          break;
        }
      }
      if (row == null) {
        rows.add(<ScorePdfTextFragment>[digit]);
      } else {
        row.add(digit);
      }
    }

    final List<ScorePdfTextFragment> numbers = <ScorePdfTextFragment>[];
    for (final List<ScorePdfTextFragment> row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
      List<ScorePdfTextFragment> token = <ScorePdfTextFragment>[];
      void flush() {
        if (token.isEmpty) return;
        numbers.add(
          ScorePdfTextFragment(
            text: token.map((item) => item.text).join(),
            left: token.first.left,
            top: token.map((item) => item.top).reduce(math.min),
            right: token.map((item) => item.right).reduce(math.max),
            bottom: token.map((item) => item.bottom).reduce(math.max),
          ),
        );
        token = <ScorePdfTextFragment>[];
      }

      for (final ScorePdfTextFragment digit in row) {
        if (token.isNotEmpty && digit.left - token.last.right > 0.006) flush();
        token.add(digit);
      }
      flush();
    }
    return numbers;
  }

  double _structureSimilarity(
    LocalScoreAnalysis reference,
    LocalScoreAnalysis candidate,
  ) {
    final double referenceLength = reference.playbackLength.toDouble();
    final double candidateLength = candidate.playbackLength.toDouble();
    final double longer = math.max(referenceLength, candidateLength);
    final double rangeSimilarity =
        longer <= 0 ? 0 : math.min(referenceLength, candidateLength) / longer;
    final double anchorSimilarity = _jaccard(
      reference.printedMeasures.map((value) => '$value').toSet(),
      candidate.printedMeasures.map((value) => '$value').toSet(),
    );
    // 시스템 줄바꿈은 파트마다 다르므로 전체 마디 범위를 더 크게 본다.
    return 0.75 * rangeSimilarity + 0.25 * anchorSimilarity;
  }

  MeasureMap _buildMap(List<_MeasureLabel> labels) {
    if (labels.isEmpty) return MeasureMap(const <ScoreAnchor>[]);
    final List<_MeasureLabel> usable = <_MeasureLabel>[...labels];
    if (usable.first.measure > 1) {
      final _MeasureLabel first = usable.first;
      usable.insert(
        0,
        _MeasureLabel(
          page: 0,
          y: first.page == 0 ? (first.y * 0.55).clamp(0.08, 0.34) : 0.16,
          x: first.x,
          measure: 1,
        ),
      );
    }

    final List<int> gaps = <int>[];
    for (int i = 1; i < usable.length; i++) {
      final int gap = usable[i].measure - usable[i - 1].measure;
      if (gap > 0 && gap <= 32) gaps.add(gap);
    }
    gaps.sort();
    final int fallbackGap = gaps.isEmpty ? 4 : gaps[gaps.length ~/ 2];
    final double xStart =
        (usable.map((label) => label.x).reduce(math.min) + 0.022)
            .clamp(0.06, 0.18);

    return MeasureMap(
      List<ScoreAnchor>.generate(usable.length, (int index) {
        final _MeasureLabel label = usable[index];
        final double end = index + 1 < usable.length
            ? usable[index + 1].measure.toDouble()
            : (label.measure + fallbackGap).toDouble();
        return ScoreAnchor(
          page: label.page,
          y: label.y,
          measure: label.measure.toDouble(),
          endMeasure: end,
          xStart: xStart,
          xEnd: 0.965,
        );
      }),
    );
  }

  static String _identityKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^가-힣a-z0-9]'), '');

  static String _artistKey(String value) {
    final Match? korean = RegExp(r'\(([가-힣]{2,})\)').firstMatch(value);
    return _identityKey(korean?.group(1) ?? value);
  }

  static double _dice(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.contains(b) || b.contains(a)) {
      return math.min(a.length, b.length) / math.max(a.length, b.length);
    }
    if (a.length == 1 || b.length == 1) return a == b ? 1 : 0;
    final Set<String> aa = <String>{
      for (int i = 0; i + 1 < a.length; i++) a.substring(i, i + 2),
    };
    final Set<String> bb = <String>{
      for (int i = 0; i + 1 < b.length; i++) b.substring(i, i + 2),
    };
    return 2 * aa.intersection(bb).length / (aa.length + bb.length);
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }
}

class _Title {
  final String display;
  final String key;
  final String artist;
  final String artistKey;

  const _Title({
    required this.display,
    required this.key,
    required this.artist,
    required this.artistKey,
  });
}

class _TextLine {
  final List<ScorePdfTextFragment> fragments = <ScorePdfTextFragment>[];

  void add(ScorePdfTextFragment fragment) => fragments.add(fragment);

  double get centerY =>
      fragments.map((fragment) => fragment.centerY).reduce((a, b) => a + b) /
      fragments.length;

  double get averageHeight =>
      fragments
          .map((fragment) => fragment.bottom - fragment.top)
          .reduce((a, b) => a + b) /
      fragments.length;

  String get text {
    final List<ScorePdfTextFragment> ordered = <ScorePdfTextFragment>[
      ...fragments
    ]..sort((a, b) => a.left.compareTo(b.left));
    return ordered.map((fragment) => fragment.text.trim()).join(' ').trim();
  }

  double get score =>
      averageHeight * 100 +
      text.replaceAll(RegExp(r'[^가-힣A-Za-z0-9]'), '').length * 0.01;
}

class _MeasureLabel {
  final int page;
  final double y;
  final double x;
  final int measure;

  const _MeasureLabel({
    required this.page,
    required this.y,
    required this.x,
    required this.measure,
  });

  static int readingOrder(_MeasureLabel a, _MeasureLabel b) {
    final int byPage = a.page.compareTo(b.page);
    return byPage != 0 ? byPage : a.y.compareTo(b.y);
  }
}

class _EndingLabel {
  final int page;
  final ScorePdfTextFragment fragment;

  const _EndingLabel(this.page, this.fragment);
}
