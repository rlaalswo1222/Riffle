import 'package:barlink/models/measure_map.dart';
import 'package:barlink/models/score_anchor.dart';
import 'package:barlink/services/local_score_analyzer.dart';
import 'package:barlink/services/score_pdf_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final LocalScoreAnalyzer analyzer = LocalScoreAnalyzer();

  test('부른 사람은 작사·작곡이 아니라 "OOO 노래" 줄에서 읽는다', () {
    String artistOf(String body) => analyzer
        .analyzePages(<ScorePdfPageText>[
          _page(title: '노래는 불빛처럼 달린다', body: body, measures: const <int>[5, 9, 13]),
        ])
        .artist;
    // 제목의 "노래는"이나 가사의 "노래"는 부른 사람 표시가 아니다.
    expect(
      artistOf('akbobada.com\n내 노래 들어줘\n페퍼톤스 (PEPPERTONES) 작사\n'
          '페퍼톤스 (PEPPERTONES) 작곡\n유다빈밴드 노래\n'
          "유다빈밴드의 'Twenty Plenty' (2024.04) 수록곡"),
      '유다빈밴드',
    );
    expect(artistOf("김세진 작사\n서정진 작곡 IU(아이유)의 1집 'Growing Up' (2009.04)수록곡 IU(아이유) 노래"), '아이유');
    expect(artistOf('윤하 작사\n윤하, JEWNO 작곡\n윤하 (YOUNHA) 노래'), '윤하');
    // "노래" 줄이 없으면 수록곡 줄에서, 그것도 없으면 작사가를 쓰지 않고 비워 둔다.
    expect(artistOf("한로로 작사\n한로로의 '먹이사슬' (2024.04) 수록곡"), '한로로');
    expect(artistOf('김세진 작사\n서정진 작곡'), '');
  });

  test('파일 해시 없이 제목·내용·마디 번호로 같은 곡을 연결한다', () {
    final LocalScoreAnalysis keyboard =
        analyzer.analyzePages(<ScorePdfPageText>[
      _page(
        title: '밤 하늘',
        body: '우리 함께 걷던 길 Am F C G 다시 만나 노래해',
        measures: const <int>[5, 9, 13, 17],
      ),
    ]);
    final LocalScoreAnalysis guitar = analyzer.analyzePages(<ScorePdfPageText>[
      _page(
        title: '밤 하늘',
        body: 'Guitar TAB 우리 함께 걷던 길 Am F C G 다시 만나 노래해',
        measures: const <int>[5, 9, 13, 17],
      ),
    ]);

    expect(keyboard.isUsable, isTrue);
    expect(guitar.isUsable, isTrue);
    expect(keyboard.map.length, 5);
    expect(keyboard.map.anchors.first.measure, 1);
    expect(keyboard.map.anchors.last.endMeasure, 21);

    final ScoreMatchResult match = analyzer.compare(keyboard, guitar);
    expect(match.accepted, isTrue);
    expect(match.titleSimilarity, 1);
    expect(match.confidence, greaterThan(0.7));
  });

  test('마디 구조가 비슷해도 제목과 음악 내용이 다른 곡은 거절한다', () {
    final LocalScoreAnalysis reference =
        analyzer.analyzePages(<ScorePdfPageText>[
      _page(
        title: '첫 번째 노래',
        body: '햇살 아래 너와 걷는다 따뜻한 바람 따라서 푸른 언덕을 '
            '지나 오래된 추억 속의 약속을 다시 노래한다 C Am F G',
        measures: const <int>[5, 9, 13, 17],
      ),
    ]);
    final LocalScoreAnalysis other = analyzer.analyzePages(<ScorePdfPageText>[
      _page(
        title: '완전히 다른 곡',
        body: '차가운 겨울 혼자 남았다 얼어붙은 거리 위로 낯선 그림자가 '
            '흐르고 닫힌 창문 너머 새벽빛만 기다린다 D Bm G A',
        measures: const <int>[5, 9, 13, 17],
      ),
    ]);

    final ScoreMatchResult match = analyzer.compare(reference, other);
    expect(match.rejected, isTrue);
    expect(match.reason, contains('제목'));
  });

  test('분리된 한글 제목과 세로로 합쳐진 숫자를 복원해 드럼 축약보를 승인한다', () {
    final List<int> keyboardMeasures = <int>[
      5,
      9,
      14,
      18,
      22,
      26,
      30,
      34,
      38,
      42,
      46,
      51,
      55,
      59,
      63,
      67,
      70,
    ];
    final List<int> drumMeasures = <int>[
      5,
      9,
      14,
      18,
      22,
      26,
      30,
      34,
      36,
      40,
      44,
      46,
      50,
      54,
      59,
      63,
      67,
      71,
      76,
    ];
    final LocalScoreAnalysis keyboard = analyzer.analyzePages(
      <ScorePdfPageText>[
        _fragmentedPage(
          titleParts: const <String>['내', '손을', '잡아'],
          body: 'IU(아이유)\n노래\n느낌이 오잖아 떨리고 있잖아 언제까지 넌 모른 척할 거니 '
              '내 손을 잡아 A DM7 F#m7',
          measures: keyboardMeasures,
        ),
      ],
    );
    final LocalScoreAnalysis drum = analyzer.analyzePages(
      <ScorePdfPageText>[
        _fragmentedPage(
          titleParts: const <String>['아이유', '-', '내', '손', '을', '잡아', 'Lv1'],
          body:
              'arranged by yeol drum Intro Chorus Interlude Verse A Verse B Ending',
          measures: drumMeasures,
          mergeFirstTwoNumbers: true,
        ),
      ],
    );

    expect(keyboard.titleKey, '내손을잡아');
    expect(drum.titleKey, '내손을잡아');
    expect(keyboard.artistKey, '아이유');
    expect(drum.artistKey, '아이유');
    expect(drum.printedMeasures.take(2), <int>[5, 9]);
    expect(drum.hasRichContent, isFalse);

    final ScoreMatchResult match = analyzer.compare(keyboard, drum);
    expect(match.accepted, isTrue);
    expect(match.contentCompared, isFalse);
    expect(match.titleSimilarity, 1);
    expect(match.structureSimilarity, greaterThan(0.75));
    expect(match.confidence, greaterThan(0.9));
  });

  test('증거가 부족하면 다른 곡으로 단정하지 않고 사용자 확인으로 보낸다', () {
    final LocalScoreAnalysis reference = analyzer.analyzePages(
      <ScorePdfPageText>[
        _page(
          title: '밤하늘',
          body: '짧은 악보 C G',
          measures: const <int>[5, 9, 13],
        ),
      ],
    );
    final LocalScoreAnalysis candidate = analyzer.analyzePages(
      <ScorePdfPageText>[
        _page(
          title: '밤하늘 라이브',
          body: 'Drum Intro Verse',
          measures: const <int>[5, 9, 13],
        ),
      ],
    );

    expect(analyzer.compare(reference, candidate).needsReview, isTrue);
  });

  test('마디 번호를 충분히 읽지 못한 PDF는 분석 단계에서 거절한다', () {
    final LocalScoreAnalysis result = analyzer.analyzePages(<ScorePdfPageText>[
      _page(
        title: '마디 없는 악보',
        body: '가사와 코드 C F G',
        measures: const <int>[5],
      ),
    ]);

    expect(result.isUsable, isFalse);
    expect(result.failureReason, contains('마디 번호'));
  });

  test('1번·2번 엔딩 텍스트를 반복 연주 순서에 반영한다', () {
    final MeasureMap imageMap = MeasureMap(const <ScoreAnchor>[
      ScoreAnchor(
        page: 0,
        y: 0.20,
        measure: 1,
        endMeasure: 5,
        barlines: <double>[0.1, 0.3, 0.5, 0.7, 0.9],
        systemBottom: 0.34,
        repeatStarts: <int>[0],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.40,
        measure: 5,
        endMeasure: 9,
        barlines: <double>[0.1, 0.3, 0.5, 0.7, 0.9],
        systemBottom: 0.54,
        repeatEnds: <int>[4],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.60,
        measure: 9,
        endMeasure: 13,
        barlines: <double>[0.1, 0.3, 0.5, 0.7, 0.9],
        systemBottom: 0.74,
      ),
    ]);
    const ScorePdfPageText page = ScorePdfPageText(
      fullText: '1. 2.',
      fragments: <ScorePdfTextFragment>[
        ScorePdfTextFragment(
          text: '1.',
          left: 0.51,
          top: 0.365,
          right: 0.54,
          bottom: 0.385,
        ),
        ScorePdfTextFragment(
          text: '2.',
          left: 0.11,
          top: 0.565,
          right: 0.14,
          bottom: 0.585,
        ),
      ],
    );

    final MeasureMap result = analyzer
        .markRepeatEndingsForTesting(imageMap, <ScorePdfPageText>[page]);
    expect(result.repeats.single.firstEndingStart, 7);
    expect(result.repeats.single.secondEndingStart, 9);
    expect(
      result.playbackBars.map((bar) => bar.physicalMeasure).toList(),
      <int>[1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12],
    );
  });

  test('"(2024.04)"의 2와 마침표는 2번 괄호가 아니다', () {
    const ScorePdfTextFragment ch =
        ScorePdfTextFragment(text: '', left: 0, top: 0, right: 0, bottom: 0);
    ScorePdfTextFragment at(String text, double left) => ScorePdfTextFragment(
        text: text, left: left, top: 0.15, right: left + 0.006, bottom: 0.16);
    final ScorePdfPageText page = ScorePdfPageText(
      fullText: '(2024.04)',
      fragments: const <ScorePdfTextFragment>[ch],
      characters: <ScorePdfTextFragment>[
        at('2', 0.300),
        at('4', 0.306),
        at('.', 0.312),
        at('0', 0.318),
      ],
    );
    final MeasureMap result = analyzer.markRepeatEndingsForTesting(
      MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
            page: 0,
            y: 0.2,
            measure: 1,
            endMeasure: 5,
            barlines: <double>[0.1, 0.3, 0.5, 0.7, 0.9]),
      ]),
      <ScorePdfPageText>[page],
    );
    expect(result.anchors.single.secondEndings, isEmpty);
  });

  test('반복을 펼쳐 쓴 파트는 연주 길이에 맞춰 오검출 반복을 제거한다', () {
    LocalScoreAnalysis analysis(MeasureMap map) => LocalScoreAnalysis(
          title: '내 손을 잡아',
          titleKey: '내손을잡아',
          artist: '아이유',
          artistKey: '아이유',
          contentFeatures: const <String>{},
          printedMeasures: const <int>[1, 5, 36, 80],
          map: map,
          analysisConfidence: 1,
        );

    final LocalScoreAnalysis keyboard = analysis(MeasureMap(const [
      ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 5),
      ScoreAnchor(
        page: 0,
        y: 0.2,
        measure: 5,
        endMeasure: 36,
        repeatStarts: <int>[0],
        repeatEnds: <int>[31],
        firstEndings: <int>[8],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.3,
        measure: 36,
        endMeasure: 73,
        secondEndings: <int>[0],
      ),
    ]));
    final LocalScoreAnalysis expandedDrum = analysis(MeasureMap(const [
      ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 50),
      ScoreAnchor(
        page: 0,
        y: 0.2,
        measure: 50,
        endMeasure: 59,
        repeatStarts: <int>[0],
        repeatEnds: <int>[9],
      ),
      ScoreAnchor(page: 0, y: 0.3, measure: 59, endMeasure: 80),
    ]));

    final List<LocalScoreAnalysis> aligned =
        analyzer.alignPlaybackTimelines([keyboard, expandedDrum]);
    expect(aligned[0].map.hasRepeats, isTrue);
    expect(aligned[0].map.playbackBars[35].physicalMeasure, 5);
    expect(aligned[1].map.hasRepeats, isFalse);
    expect(aligned[1].map.playbackBars[35].physicalMeasure, 36);
  });

  test('ending-supported repeat survives adjacent detector noise', () {
    LocalScoreAnalysis analysis(MeasureMap map) => LocalScoreAnalysis(
          title: '내 손을 잡아',
          titleKey: '내손을잡아',
          artist: '아이유',
          artistKey: '아이유',
          contentFeatures: const <String>{},
          printedMeasures: const <int>[1, 5, 36, 80],
          map: map,
          analysisConfidence: 1,
        );

    final LocalScoreAnalysis noisyKeyboard = analysis(MeasureMap(const [
      ScoreAnchor(
        page: 0,
        y: 0.1,
        measure: 1,
        endMeasure: 5,
        repeatStarts: <int>[0],
        repeatEnds: <int>[4],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.2,
        measure: 5,
        endMeasure: 9,
        repeatStarts: <int>[0],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.3,
        measure: 9,
        endMeasure: 14,
        repeatStarts: <int>[0, 3],
        firstEndings: <int>[4],
      ),
      ScoreAnchor(
        page: 1,
        y: 0.1,
        measure: 14,
        endMeasure: 34,
        repeatStarts: <int>[0],
      ),
      ScoreAnchor(
        page: 2,
        y: 0.1,
        measure: 34,
        endMeasure: 38,
        repeatStarts: <int>[2],
        repeatEnds: <int>[2],
        secondEndings: <int>[2],
      ),
      ScoreAnchor(page: 3, y: 0.1, measure: 38, endMeasure: 67),
      ScoreAnchor(
        page: 4,
        y: 0.1,
        measure: 67,
        endMeasure: 70,
        repeatStarts: <int>[0, 1],
        repeatEnds: <int>[1],
      ),
      ScoreAnchor(page: 4, y: 0.2, measure: 70, endMeasure: 73),
    ]));
    final LocalScoreAnalysis noisyDrum = analysis(MeasureMap(const [
      ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 50),
      ScoreAnchor(
        page: 1,
        y: 0.1,
        measure: 50,
        endMeasure: 59,
        repeatStarts: <int>[0],
        repeatEnds: <int>[9],
      ),
      ScoreAnchor(page: 1, y: 0.2, measure: 59, endMeasure: 80),
    ]));

    // 36마디(2번 엔딩 자리)의 시작표는 불가능한 위치라 처음부터 걸러진다.
    expect(noisyKeyboard.map.repeats, hasLength(2));
    final List<LocalScoreAnalysis> aligned =
        analyzer.alignPlaybackTimelines(<LocalScoreAnalysis>[
      noisyKeyboard,
      noisyDrum,
    ]);

    expect(aligned[0].map.repeats, hasLength(1));
    expect(aligned[0].map.repeats.single.startMeasure, 5);
    expect(aligned[0].map.repeats.single.endMeasure, 36);
    expect(aligned[0].map.playbackBars[35].physicalMeasure, 5);
    expect(aligned[1].map.hasRepeats, isFalse);
    expect(aligned[1].map.playbackBars[35].physicalMeasure, 36);
  });

  test('반복이 아직 없어도 엔딩 숫자를 찾고 타브 숫자열은 제외한다', () {
    final MeasureMap imageMap = MeasureMap(const <ScoreAnchor>[
      ScoreAnchor(
        page: 0,
        y: 0.1,
        measure: 1,
        endMeasure: 77,
        xStart: 0.05,
        xEnd: 0.95,
        barlines: <double>[0.05, 0.95],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.4,
        measure: 77,
        endMeasure: 97,
        xStart: 0.05,
        xEnd: 0.95,
        barlines: <double>[0.05, 0.95],
        repeatEnds: <int>[20],
      ),
      ScoreAnchor(
        page: 0,
        y: 0.7,
        measure: 97,
        endMeasure: 109,
        xStart: 0.05,
        xEnd: 0.95,
        barlines: <double>[0.05, 0.95],
      ),
    ]);
    const ScorePdfPageText page = ScorePdfPageText(
      fullText: '1 2 2 2',
      fragments: <ScorePdfTextFragment>[
        ScorePdfTextFragment(
          text: '1',
          left: 0.11,
          top: 0.375,
          right: 0.12,
          bottom: 0.385,
        ),
        ScorePdfTextFragment(
          text: '2',
          left: 0.11,
          top: 0.675,
          right: 0.12,
          bottom: 0.685,
        ),
        ScorePdfTextFragment(
          text: '2',
          left: 0.20,
          top: 0.075,
          right: 0.21,
          bottom: 0.085,
        ),
        ScorePdfTextFragment(
          text: '2',
          left: 0.25,
          top: 0.075,
          right: 0.26,
          bottom: 0.085,
        ),
        ScorePdfTextFragment(
          text: '2',
          left: 0.30,
          top: 0.075,
          right: 0.31,
          bottom: 0.085,
        ),
      ],
    );

    final MeasureMap result = analyzer
        .markRepeatEndingsForTesting(imageMap, <ScorePdfPageText>[page]);
    expect(result.repeats, hasLength(1));
    expect(result.repeats.single.startMeasure, 1);
    expect(result.repeats.single.endMeasure, 97);
    expect(result.repeats.single.firstEndingStart, 77);
    expect(result.repeats.single.secondEndingStart, 97);
  });
}

ScorePdfPageText _fragmentedPage({
  required List<String> titleParts,
  required String body,
  required List<int> measures,
  bool mergeFirstTwoNumbers = false,
}) {
  final List<ScorePdfTextFragment> titleFragments = <ScorePdfTextFragment>[];
  double titleX = 0.2;
  for (final String part in titleParts) {
    final double width = 0.02 + part.length * 0.018;
    titleFragments.add(
      ScorePdfTextFragment(
        text: part,
        left: titleX,
        top: 0.035,
        right: titleX + width,
        bottom: 0.065,
      ),
    );
    titleX += width + 0.008;
  }

  final List<ScorePdfTextFragment> characters = <ScorePdfTextFragment>[];
  for (int index = 0; index < measures.length; index++) {
    final String value = '${measures[index]}';
    final double y = 0.16 + index * 0.035;
    for (int digit = 0; digit < value.length; digit++) {
      characters.add(
        ScorePdfTextFragment(
          text: value[digit],
          left: 0.06 + digit * 0.008,
          top: y,
          right: 0.066 + digit * 0.008,
          bottom: y + 0.008,
        ),
      );
    }
  }

  return ScorePdfPageText(
    fullText: '${titleParts.join(' ')}\n$body\n${measures.join('\n')}',
    fragments: <ScorePdfTextFragment>[
      ...titleFragments,
      if (mergeFirstTwoNumbers)
        const ScorePdfTextFragment(
          text: '59',
          left: 0.06,
          top: 0.16,
          right: 0.07,
          bottom: 0.24,
        ),
    ],
    characters: characters,
  );
}

ScorePdfPageText _page({
  required String title,
  required String body,
  required List<int> measures,
}) {
  return ScorePdfPageText(
    fullText: '$title\n$body\n${measures.join('\n')}',
    fragments: <ScorePdfTextFragment>[
      ScorePdfTextFragment(
        text: title,
        left: 0.3,
        top: 0.04,
        right: 0.7,
        bottom: 0.075,
      ),
      for (int i = 0; i < measures.length; i++)
        ScorePdfTextFragment(
          text: '${measures[i]}',
          left: 0.065,
          top: 0.32 + i * 0.14,
          right: 0.085,
          bottom: 0.334 + i * 0.14,
        ),
    ],
  );
}
