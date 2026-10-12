import 'dart:math' as math;
import 'dart:typed_data';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import 'score_pdf_document.dart';

/// 마디마다 어떤 코드가 울리는지. 실시간 추종기가 소리와 대조하는 기준이다.
///
/// 파트보에 인쇄된 코드 심볼은 그 파트가 쉬는 마디에서도 밴드 전체의
/// 화성을 적은 것이다. 그래서 내 파트가 쉼표여도 그대로 쓴다.
class ChordChart {
  /// 1마디부터 마지막 마디까지, 마디당 4박의 코드 템플릿 번호. 코드가
  /// 아직 한 번도 나오지 않은 앞부분은 -1(대조하지 않음)이다.
  final Int32List beatTemplates;

  /// 템플릿 번호 → 12음 크로마 벡터(L2 정규화).
  final List<Float64List> templates;

  /// 템플릿 번호 → 코드 이름. 화면 표시용.
  final List<String> names;

  /// 코드 심볼을 실제로 읽은 마디 수. 너무 적으면 추종할 수 없다.
  final int measuresWithSymbols;

  /// 악보에 인쇄된 템포(♩=170). 못 찾으면 null.
  final double? printedBpm;

  /// 곡 중간에 바뀌는 템포: 인쇄 마디 번호 → 그 마디부터의 ♩ 값.
  /// 먹이사슬 68마디처럼 ♩=106에서 ♩=196으로 바뀌는 곡이 있다.
  final Map<int, double> tempoChanges;

  const ChordChart({
    required this.beatTemplates,
    required this.templates,
    required this.names,
    required this.measuresWithSymbols,
    required this.printedBpm,
    this.tempoChanges = const <int, double>{},
  });

  /// 인쇄 마디 [measure]에서의 ♩ 값. 템포 표시가 없으면 [printedBpm].
  double? tempoAt(int measure) {
    double? bpm = printedBpm;
    int from = -1;
    tempoChanges.forEach((int m, double v) {
      if (m <= measure && m > from) {
        from = m;
        bpm = v;
      }
    });
    return bpm;
  }

  /// 처음 템포에 대한 [measure]의 빠르기 비율. 템포가 안 바뀌면 1.
  double rateAt(int measure) {
    final double? base = printedBpm, here = tempoAt(measure);
    return base == null || here == null || base <= 0 ? 1 : here / base;
  }

  static const int beatsPerMeasure = 4;

  int get measureCount => beatTemplates.length ~/ beatsPerMeasure;

  /// 인쇄 마디 [measure]의 [beat]번째 박 템플릿. 범위 밖이면 -1.
  int templateAt(int measure, int beat) {
    final int index = (measure - 1) * beatsPerMeasure + beat;
    return index >= 0 && index < beatTemplates.length
        ? beatTemplates[index]
        : -1;
  }

  String? chordNameAt(int measure) {
    final int id = templateAt(measure, 0);
    return id < 0 ? null : names[id];
  }

  /// 마디별 코드 이름으로 직접 만든다. 한 마디에 코드가 여럿이면 박을 나눠
  /// 갖는다(2개: 1·3박, 3개: 1·3·4박, 4개: 박마다).
  factory ChordChart.fromMeasureChords(
    Map<int, List<String>> chords,
    int lastMeasure, {
    double? bpm,
  }) {
    final List<String> names = <String>[];
    final List<Float64List> templates = <Float64List>[];
    final Map<String, int> ids = <String, int>{};
    final Int32List beats = Int32List(lastMeasure * beatsPerMeasure)
      ..fillRange(0, lastMeasure * beatsPerMeasure, -1);
    const Map<int, List<int>> split = <int, List<int>>{
      1: <int>[0, 0, 0, 0],
      2: <int>[0, 0, 1, 1],
      3: <int>[0, 0, 1, 2],
      4: <int>[0, 1, 2, 3],
    };
    int current = -1;
    for (int bar = 1; bar <= lastMeasure; bar++) {
      final List<String> list = (chords[bar] ?? const <String>[])
          .where((String c) => parseChord(c) != null)
          .take(4)
          .toList();
      for (int b = 0; b < beatsPerMeasure; b++) {
        if (list.isNotEmpty) {
          final String name = list[split[list.length]![b]];
          current = ids.putIfAbsent(name, () {
            names.add(name);
            templates.add(chordVector(parseChord(name)!));
            return names.length - 1;
          });
        }
        beats[(bar - 1) * beatsPerMeasure + b] = current;
      }
    }
    return ChordChart(
      beatTemplates: beats,
      templates: templates,
      names: names,
      measuresWithSymbols: chords.length,
      printedBpm: bpm,
    );
  }

  /// PDF 텍스트 계층에서 코드 심볼을 찾아 마디에 붙인다.
  static ChordChart fromPdf(List<ScorePdfPageText> pages, MeasureMap map) {
    final int lastMeasure = map.anchors.isEmpty
        ? 0
        : map.anchors
            .map((ScoreAnchor a) => (a.endMeasure ?? a.measure + 4).ceil() - 1)
            .reduce(math.max);

    // 마디 번호 → [(마디 안 위치, 코드)]
    final Map<int, List<(double, String)>> found = <int, List<(double, String)>>{};
    for (int page = 0; page < pages.length; page++) {
      final List<ScoreAnchor> lines = map.onPage(page);
      if (lines.isEmpty) continue;
      // 바로 앞에서 읽은 코드. "/G"처럼 베이스만 적힌 표기를 해석하는 데 쓴다.
      (List<(double, String)>, int, double)? previous;
      for (final _Token token in _tokens(pages[page])) {
        // 코드 앞에 붙어 읽히는 괄호 번호("2D♭")·코다 기호("𝄌B7")는 뗀다.
        // 코드 이름은 근음 글자로 시작한다.
        String text = _canonical(token.text).replaceFirst(RegExp(r'^[^A-GN/(]+'), '');
        // "( N.C.)"처럼 괄호가 붙어 나오는 일이 많다.
        final bool noChord = _noChord.hasMatch(text.replaceAll(RegExp(r'[()\s]'), ''));
        final Match? slash = _slashOnly.firstMatch(text);
        if (slash != null) {
          // "Am7 … /G" = 같은 코드에 베이스만 G. 같은 줄에 앞 코드가 있어야 한다.
          if (previous == null) continue;
          final (List<(double, String)> list, int index, double y) = previous;
          if ((y - token.centerY).abs() > 0.01) continue;
          text = '${list[index].$2.split('/').first}/${slash.group(1)}';
          if (token.x - list[index].$1 < 0.03) {
            list[index] = (list[index].$1, text); // 한 심볼이 둘로 쪼개진 것
            continue;
          }
        }
        if (!noChord && parseChord(text) == null) continue;
        final ScoreAnchor? line = _lineOf(lines, map, token.centerY);
        if (line == null) continue;
        // 코드 심볼은 오선보다 위에 있으므로, 줄을 찾은 뒤에는 그 줄의 y로 묻는다.
        final double? measure = map.measureAt(page, token.x, line.y + 1e-6);
        if (measure == null) continue;
        final int bar = measure.floor();
        if (bar < 1 || bar > lastMeasure) continue;
        final List<(double, String)> list =
            found.putIfAbsent(bar, () => <(double, String)>[]);
        list.add((token.x, noChord ? _nc : text));
        previous = noChord ? null : (list, list.length - 1, token.centerY);
      }
    }

    final List<String> names = <String>[];
    final List<Float64List> templates = <Float64List>[];
    final Map<String, int> ids = <String, int>{};
    int idOf(String name) => ids.putIfAbsent(name, () {
          names.add(name);
          templates.add(chordVector(parseChord(name)!));
          return names.length - 1;
        });

    final Int32List beats = Int32List(math.max(lastMeasure, 0) * beatsPerMeasure)
      ..fillRange(0, math.max(lastMeasure, 0) * beatsPerMeasure, -1);
    int current = -1;
    for (int bar = 1; bar <= lastMeasure; bar++) {
      final List<(double, String)> chords = (found[bar] ?? <(double, String)>[])
        ..sort((a, b) => a.$1.compareTo(b.$1));
      // 마디 안 박 위치: 첫 코드는 1박. 나머지는 첫 코드에서 오른쪽 마디선까지의
      // 비율로 정한다. 줄 첫 마디는 음자리표·조표 때문에 왼쪽 경계가 믿을 수 없다.
      final Map<int, int> changes = <int, int>{};
      if (chords.isNotEmpty) {
        final MeasureBand? band = map.bandOf(bar + 0.5);
        final double x0 = chords.first.$1;
        final double right = band?.right ?? 1.0;
        for (int i = 0; i < chords.length; i++) {
          final double rel =
              right > x0 ? (chords[i].$1 - x0) / (right - x0) : 0;
          final int beat = i == 0
              ? 0
              : (rel * beatsPerMeasure).round().clamp(1, beatsPerMeasure - 1);
          changes[beat] = chords[i].$2 == _nc ? -1 : idOf(chords[i].$2);
        }
      }
      for (int b = 0; b < beatsPerMeasure; b++) {
        current = changes[b] ?? current;
        beats[(bar - 1) * beatsPerMeasure + b] = current;
      }
    }

    final double? printed = _printedTempo(pages);
    return ChordChart(
      beatTemplates: beats,
      templates: templates,
      names: names,
      measuresWithSymbols: found.length,
      printedBpm: printed,
      tempoChanges: _tempoChanges(pages, map, printed, lastMeasure),
    );
  }

  /// 곡 중간의 템포 표시(♩=196)를 찾아 그 줄의 마디에 붙인다. 표시는 마디
  /// 첫머리 위에 찍히므로 가장 가까운 마디의 시작부터 적용한다.
  static Map<int, double> _tempoChanges(
    List<ScorePdfPageText> pages,
    MeasureMap map,
    double? printed,
    int lastMeasure,
  ) {
    final Map<int, double> changes = <int, double>{};
    double? current = printed;
    for (int page = 0; page < pages.length; page++) {
      final List<ScoreAnchor> lines = map.onPage(page);
      if (lines.isEmpty) continue;
      final List<ScorePdfTextFragment> chars = pages[page].characters;
      final List<(double, double, double)> marks = <(double, double, double)>[]; // (y, x, bpm)
      for (final ScorePdfTextFragment eq in chars) {
        if (eq.text != '=') continue;
        final List<ScorePdfTextFragment> digits = chars
            .where((c) =>
                RegExp(r'^\d$').hasMatch(c.text) &&
                (c.centerY - eq.centerY).abs() <= 0.006 &&
                c.left >= eq.right - 0.002 &&
                c.left - eq.right <= 0.03)
            .toList()
          ..sort((a, b) => a.left.compareTo(b.left));
        if (digits.isEmpty) continue;
        final StringBuffer number = StringBuffer(digits.first.text);
        for (int i = 1; i < digits.length && digits[i].left - digits[i - 1].right <= 0.006; i++) {
          number.write(digits[i].text);
        }
        final double bpm = double.tryParse(number.toString()) ?? 0;
        if (bpm < 40 || bpm > 260) continue;
        marks.add((eq.centerY, eq.centerX, bpm));
      }
      marks.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
      for (final (double y, double x, double bpm) in marks) {
        // 템포 표시는 오선과 코드 심볼보다 위에 있다. 바로 아래 줄을 찾는다.
        ScoreAnchor? line;
        for (final ScoreAnchor l in lines) {
          if (l.y >= y - 0.01 && (line == null || l.y < line.y)) line = l;
        }
        if (line == null || line.y - y > 0.08) continue;
        final double? measure = map.measureAt(page, x, line.y + 1e-6);
        if (measure == null) continue;
        final int bar = measure.floor().clamp(1, math.max(1, lastMeasure));
        if (bar <= 1 || current == bpm) {
          current ??= bpm;
          continue;
        }
        changes[bar] = bpm;
        current = bpm;
      }
    }
    return changes;
  }

  /// 글자 좌표로 단어를 다시 나눈다.
  ///
  /// PDF 텍스트 조각은 믿을 수 없다. "A"와 "E/G#"처럼 떨어진 두 코드가 한
  /// 조각으로 붙어 나오기도 하고, "F#m7"의 위첨자 "m7"이 따로 떨어져
  /// 나오기도 한다. 그래서 세로로 겹치는 글자를 한 줄로 묶고(위첨자 포함),
  /// 가로 간격이 벌어지는 곳에서 자른다.
  static List<_Token> _tokens(ScorePdfPageText page) {
    final List<ScorePdfTextFragment> chars = page.characters.isNotEmpty
        ? (<ScorePdfTextFragment>[...page.characters]..sort((a, b) => a.top.compareTo(b.top)))
        : const <ScorePdfTextFragment>[];
    if (chars.isEmpty) {
      return <_Token>[
        for (final ScorePdfTextFragment f in page.fragments)
          _Token(f.text.trim(), f.left + 0.004, f.centerY),
      ];
    }
    final List<List<ScorePdfTextFragment>> rows = <List<ScorePdfTextFragment>>[];
    final List<(double, double)> spans = <(double, double)>[];
    for (final ScorePdfTextFragment c in chars) {
      int row = -1;
      for (int r = spans.length - 1; r >= 0 && row < 0; r--) {
        final double overlap =
            math.min(spans[r].$2, c.bottom) - math.max(spans[r].$1, c.top);
        if (overlap > 0.3 * (c.bottom - c.top)) row = r;
      }
      if (row < 0) {
        rows.add(<ScorePdfTextFragment>[c]);
        spans.add((c.top, c.bottom));
      } else {
        rows[row].add(c);
      }
    }
    final List<_Token> out = <_Token>[];
    for (final List<ScorePdfTextFragment> row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
      StringBuffer text = StringBuffer();
      ScorePdfTextFragment? first, prev;
      void flush() {
        if (first != null && text.isNotEmpty) {
          // 위치는 근음 글자의 가운데. 왼쪽 끝은 마디선에 걸쳐 찍히는 일이 있다.
          out.add(_Token(text.toString(), first!.centerX, first!.centerY));
        }
        text = StringBuffer();
        first = null;
      }

      for (final ScorePdfTextFragment c in row) {
        if (prev != null && c.left - prev.right > 0.0045) flush();
        first ??= c;
        text.write(c.text);
        prev = c;
      }
      flush();
    }
    return out;
  }

  /// 코드 심볼이 속한 줄. 심볼은 오선 위에 있으므로 줄의 시작 y보다
  /// 약간 위까지 그 줄로 본다.
  static ScoreAnchor? _lineOf(List<ScoreAnchor> lines, MeasureMap map, double y) {
    ScoreAnchor? best;
    for (int i = 0; i < lines.length; i++) {
      final ScoreAnchor line = lines[i];
      final double bottom = line.systemBottom ??
          (i + 1 < lines.length ? lines[i + 1].y : 1.0);
      // 첫 줄은 마디 번호가 인쇄되지 않아 y가 추정치라 여유를 넉넉히 둔다.
      if (y >= line.y - 0.06 && y <= bottom) best = line;
    }
    return best;
  }

  static double? _printedTempo(List<ScorePdfPageText> pages) {
    for (final ScorePdfPageText page in pages.take(2)) {
      final Match? m = RegExp(r'=\s*(\d{2,3})\b').firstMatch(page.fullText);
      if (m != null) {
        final double bpm = double.parse(m.group(1)!);
        if (bpm >= 40 && bpm <= 260) return bpm;
      }
    }
    return null;
  }

  static const String _nc = 'N.C.';
  static final RegExp _noChord = RegExp(r'^N\.?C\.?$');
  static final RegExp _slashOnly = RegExp(r'^/([A-G][#b]?)$');

  static String _canonical(String text) =>
      text.replaceAll('♯', '#').replaceAll('♭', 'b');
}

class _Token {
  final String text;

  /// 근음 글자의 가로 중심.
  final double x;
  final double centerY;
  const _Token(this.text, this.x, this.centerY);
}

/// 파싱된 코드: 근음, 구성음(피치 클래스), 베이스음.
class ParsedChord {
  final int root;
  final Set<int> tones;
  final int? bass;
  const ParsedChord(this.root, this.tones, this.bass);
}

const Map<String, int> _pitch = <String, int>{
  'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
};

final RegExp _chordPattern = RegExp(
  r'^([A-G])([#b♯♭]?)'
  // 숫자는 코드에 쓰는 것만 허용한다. 옆의 마디 번호(157)가 붙은 "C6157"을 거른다.
  r'((?:maj|M|min|m|dim|aug|\+|sus|add|alt|13|11|9|7|6|5|4|2|b|#|♭|♯|\(|\)|,)*)'
  r'(?:/([A-G])([#b♯♭]?))?$',
);

/// "F#m7", "A/C#", "DM7", "G7b9", "E7sus4" 같은 코드 심볼을 해석한다.
/// 코드가 아니면 null.
ParsedChord? parseChord(String text) {
  final Match? m = _chordPattern.firstMatch(text.trim());
  if (m == null) return null;
  int pc(String letter, String accidental) {
    int v = _pitch[letter]!;
    if (accidental == '#' || accidental == '♯') v += 1;
    if (accidental == 'b' || accidental == '♭') v -= 1;
    return v % 12;
  }

  final int root = pc(m.group(1)!, m.group(2)!);
  final String q = m.group(3)!;
  // 숫자 없이 'b' 같은 꼬리만 붙은 건 코드가 아니다 (예: 영어 단어 "Bb"는 코드지만 "Ebb"는 아님).
  if (q.isNotEmpty && !RegExp(r'^(maj|M|m|min|dim|aug|\+|sus|add|alt|\d)').hasMatch(q)) {
    return null;
  }
  final bool minor = RegExp(r'^(m(?!aj)|min)').hasMatch(q);
  final bool dim = q.contains('dim');
  final bool aug = q.contains('aug') || q.startsWith('+');
  final Set<int> iv = <int>{0};
  if (q.contains('sus4') || (q.contains('sus') && !q.contains('sus2'))) {
    iv.addAll(<int>[5, 7]);
  } else if (q.contains('sus2')) {
    iv.addAll(<int>[2, 7]);
  } else if (dim) {
    iv.addAll(<int>[3, 6]);
  } else if (aug) {
    iv.addAll(<int>[4, 8]);
  } else {
    iv.addAll(<int>[minor ? 3 : 4, 7]);
  }
  final bool major7 = q.contains('maj7') || q.contains('M7') || q.contains('maj');
  if (dim && q.contains('7')) {
    iv.add(9);
  } else if (major7) {
    iv.add(11);
  } else if (RegExp(r'(?<![b#])(7|9|11|13)').hasMatch(q)) {
    iv.add(10);
  }
  if (RegExp(r'(?<![b#\d])6').hasMatch(q)) iv.add(9);
  if (q.contains('b5')) {
    iv
      ..remove(7)
      ..add(6);
  }
  if (q.contains('b9')) iv.add(1);
  if (q.contains('#9')) iv.add(3);
  if (RegExp(r'(?<![b#\d])9').hasMatch(q) || q.contains('add9')) iv.add(2);

  final int? bass = m.group(4) == null ? null : pc(m.group(4)!, m.group(5) ?? '');
  return ParsedChord(root, <int>{for (final int i in iv) (root + i) % 12}, bass);
}

/// 코드 → 12음 템플릿. 구성음 1, 근음·베이스음 +0.6, L2 정규화.
Float64List chordVector(ParsedChord chord) {
  final Float64List v = Float64List(12);
  for (final int t in chord.tones) {
    v[t] = 1;
  }
  v[chord.root] += 0.6;
  if (chord.bass != null) v[chord.bass!] += 0.6;
  double n = 0;
  for (final double x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  for (int i = 0; i < 12; i++) {
    v[i] /= n;
  }
  return v;
}
