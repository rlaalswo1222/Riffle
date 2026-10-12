import 'package:barlink/models/measure_map.dart';
import 'package:barlink/models/score_anchor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 건반 악보라고 하자. 한 페이지에 네 줄, 한 줄에 네 마디.
MeasureMap keyboard() => MeasureMap(const <ScoreAnchor>[
      ScoreAnchor(page: 0, y: 0.20, measure: 1),
      ScoreAnchor(page: 0, y: 0.40, measure: 5),
      ScoreAnchor(page: 0, y: 0.60, measure: 9),
      ScoreAnchor(page: 0, y: 0.80, measure: 13),
      ScoreAnchor(page: 1, y: 0.10, measure: 17),
      ScoreAnchor(page: 1, y: 0.30, measure: 21),
    ]);

/// 같은 곡의 드럼 악보. 줄당 마디 수도, 페이지도 다르다.
/// 쉼표가 뭉쳐 있어 한 줄에 여덟 마디씩 들어간다.
MeasureMap drum() => MeasureMap(const <ScoreAnchor>[
      ScoreAnchor(page: 0, y: 0.30, measure: 1),
      ScoreAnchor(page: 0, y: 0.55, measure: 9),
      ScoreAnchor(page: 0, y: 0.80, measure: 17),
    ]);

void main() {
  group('탭 → 마디', () {
    test('줄 안에서 가로 위치만큼 마디가 나아간다', () {
      final MeasureMap m = keyboard();
      // 2번째 줄(5~9마디)의 한가운데 → 7마디
      expect(m.measureAt(0, 0.5, 0.45), 7);
      // 그 줄의 시작
      expect(m.measureAt(0, 0.0, 0.40), 5);
    });

    test('페이지가 넘어가도 이어진다', () {
      expect(keyboard().measureAt(1, 0.5, 0.15), 19);
    });

    test('첫 앵커보다 위를 누르면 아무것도 주지 않는다', () {
      // 제목이나 여백이다. 아무 마디나 골라 보내면 남의 화면이 튄다.
      expect(keyboard().measureAt(0, 0.5, 0.05), isNull);
    });

    test('마지막 줄은 줄의 시작으로만 답한다', () {
      // 다음 앵커가 없어 그 줄에 몇 마디가 들었는지 알 수 없다.
      expect(keyboard().measureAt(1, 0.9, 0.35), 21);
    });

    test('앵커가 없으면 아무것도 주지 않는다', () {
      expect(MeasureMap(const <ScoreAnchor>[]).measureAt(0, 0.5, 0.5), isNull);
    });
  });

  group('마디 → 위치', () {
    test('그 마디가 든 줄을 찾는다', () {
      final MeasureBand? b = keyboard().bandOf(7);
      expect(b, isNotNull);
      expect(b!.page, 0);
      expect(b.top, 0.40);
      expect(b.bottom, 0.60);
      expect(b.x, closeTo(0.5, 1e-9));
    });

    test('페이지 마지막 줄은 페이지 끝까지가 그 줄이다', () {
      // 다음 앵커가 다음 페이지에 있으므로 y 를 그대로 쓰면 안 된다.
      final MeasureBand b = keyboard().bandOf(14)!;
      expect(b.page, 0);
      expect(b.bottom, 1.0);
    });

    test('첫 마디보다 앞은 없다', () {
      expect(keyboard().bandOf(0), isNull);
    });
  });

  group('서로 다른 악보를 잇는다', () {
    test('건반에서 누른 자리를 드럼이 자기 악보에서 찾는다', () {
      // 이 서비스가 존재하는 이유. 건반 3페이지 두 번째 줄을 눌렀는데
      // 드럼은 그게 자기 악보 어디인지 알아야 한다.
      final double measure = keyboard().measureAt(0, 0.5, 0.45)!; // 7마디
      final MeasureBand b = drum().bandOf(measure)!;

      // 드럼에서 7마디는 첫 줄(1~9마디) 안이다.
      expect(b.page, 0);
      expect(b.top, 0.30);
      expect(b.startMeasure, 1);
      expect(b.endMeasure, 9);
      // 1~9 사이의 7 → 줄의 3/4 지점
      expect(b.x, closeTo(0.75, 1e-9));
    });

    test('첨부 건반 37마디 위치가 첨부 기타 4페이지의 같은 지점으로 간다', () {
      const double left = 0.091;
      const double right = 0.960;
      final MeasureMap attachedKeyboard = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 1,
          y: 0.4652,
          measure: 37,
          endMeasure: 41,
          xStart: left,
          xEnd: right,
        ),
      ]);
      final MeasureMap attachedGuitar = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 3,
          y: 0.0375,
          measure: 37,
          endMeasure: 41,
          xStart: left,
          xEnd: right,
        ),
      ]);

      const double keyboardX = left + (right - left) * 0.375;
      final double measure = attachedKeyboard.measureAt(1, keyboardX, 0.50)!;
      final MeasureBand guitarBand = attachedGuitar.bandOf(measure)!;

      expect(measure, closeTo(38.5, 1e-9));
      expect(guitarBand.page, 3);
      expect(guitarBand.x, closeTo(keyboardX, 1e-9));
      expect(guitarBand.left, closeTo(left + (right - left) / 4, 1e-9));
      expect(guitarBand.right, closeTo(left + (right - left) / 2, 1e-9));
    });

    test('첨부 악보의 마지막 시스템도 108마디까지 계산한다', () {
      final MeasureMap attachedGuitar = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 8,
          y: 0.6589,
          measure: 105,
          endMeasure: 109,
          xStart: 0.091,
          xEnd: 0.960,
        ),
      ]);

      final double measure = attachedGuitar.measureAt(8, 0.95, 0.80)!;
      expect(measure, greaterThan(108));
      expect(attachedGuitar.bandOf(measure)!.page, 8);
    });

    test('건반의 2페이지가 드럼에서는 1페이지다', () {
      final double measure = keyboard().measureAt(1, 0.0, 0.10)!; // 17마디
      expect(drum().bandOf(measure)!.page, 0);
    });

    test('되돌려도 같은 줄로 돌아온다', () {
      final MeasureMap m = keyboard();
      for (final double y in <double>[0.25, 0.45, 0.65, 0.85]) {
        final double measure = m.measureAt(0, 0.3, y)!;
        final MeasureBand b = m.bandOf(measure)!;
        expect(b.top <= y && y < b.bottom, isTrue,
            reason: 'y=$y → m=$measure → $b');
      }
    });
  });

  group('입력이 엉망일 때', () {
    test('마디 번호를 거꾸로 넣어도 터지지 않는다', () {
      final MeasureMap m = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.2, measure: 10),
        ScoreAnchor(page: 0, y: 0.4, measure: 3), // 사용자 실수
      ]);
      expect(m.measureAt(0, 0.5, 0.25), 10);
      expect(() => m.bandOf(10), returnsNormally);
    });

    test('정밀 좌표를 JSON으로 보존한다', () {
      const ScoreAnchor anchor = ScoreAnchor(
        page: 2,
        y: 0.4,
        measure: 33,
        xStart: 0.091,
        xEnd: 0.960,
        endMeasure: 37,
      );
      final ScoreAnchor decoded = ScoreAnchor.fromJson(anchor.toJson());
      expect(decoded.xStart, anchor.xStart);
      expect(decoded.xEnd, anchor.xEnd);
      expect(decoded.endMeasure, anchor.endMeasure);
    });

    test('균등하지 않은 실제 마디 경계를 사용한다', () {
      final MeasureMap map = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 0,
          y: 0.2,
          measure: 1,
          endMeasure: 5,
          barlines: <double>[0.1, 0.22, 0.48, 0.7, 0.9],
          systemBottom: 0.38,
        ),
      ]);

      expect(map.measureAt(0, 0.35, 0.25), closeTo(2.5, 1e-9));
      final MeasureBand band = map.bandOf(2.5)!;
      expect(band.left, 0.22);
      expect(band.right, 0.48);
      expect(band.x, 0.35);
      expect(band.bottom, 0.38);
    });

    test('넣은 순서와 상관없이 읽는 순서로 정렬한다', () {
      final MeasureMap m = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 1, y: 0.1, measure: 17),
        ScoreAnchor(page: 0, y: 0.4, measure: 5),
        ScoreAnchor(page: 0, y: 0.2, measure: 1),
      ]);
      expect(m.anchors.map((ScoreAnchor a) => a.measure).toList(),
          <double>[1, 5, 17]);
    });
  });

  group('다음 줄 마디 번호 짐작', () {
    test('앞의 간격을 그대로 이어준다', () {
      expect(keyboard().nextMeasureGuess(), 25); // 21 + 4
      expect(drum().nextMeasureGuess(), 25); // 17 + 8
    });

    test('처음에는 1마디부터', () {
      expect(MeasureMap(const <ScoreAnchor>[]).nextMeasureGuess(), 1);
    });
  });

  group('도돌이표 연주 순서', () {
    MeasureMap repeated({bool endings = false}) => MeasureMap(<ScoreAnchor>[
          const ScoreAnchor(
            page: 0,
            y: 0.2,
            measure: 1,
            endMeasure: 5,
            repeatStarts: <int>[0],
          ),
          ScoreAnchor(
            page: 0,
            y: 0.4,
            measure: 5,
            endMeasure: 9,
            repeatEnds: const <int>[4],
            firstEndings: endings ? const <int>[2] : const <int>[],
          ),
          ScoreAnchor(
            page: 0,
            y: 0.6,
            measure: 9,
            endMeasure: 13,
            secondEndings: endings ? const <int>[0] : const <int>[],
          ),
        ]);

    test('반복 구간을 실제로 두 번 펼친다', () {
      final MeasureMap map = repeated();
      expect(map.repeats, hasLength(1));
      expect(
        map.playbackBars.map((bar) => bar.physicalMeasure).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      );
    });

    test('같은 인쇄 마디를 다시 누르면 두 번째 반복 회차로 간다', () {
      final MeasureMap map = repeated();
      final PlaybackPosition first = map.playbackPositionAt(0, 0.1, 0.25)!;
      final PlaybackPosition second = map.playbackPositionAt(
        0,
        0.1,
        0.25,
        currentTimeline: first.timeline,
      )!;
      expect(first.timeline, closeTo(0.4, 1e-9));
      expect(first.repeatPass, 1);
      expect(second.timeline, closeTo(8.4, 1e-9));
      expect(second.repeatPass, 2);
    });

    test('1번 엔딩은 첫 회차에만 연주하고 2번 엔딩으로 건너뛴다', () {
      final MeasureMap map = repeated(endings: true);
      expect(map.repeats.single.firstEndingStart, 7);
      expect(map.repeats.single.secondEndingStart, 9);
      expect(
        map.playbackBars.map((bar) => bar.physicalMeasure).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12],
      );
    });

    test('1·2번 괄호가 확인되면 32마디보다 긴 반복도 시작표로 돌아간다', () {
      // 먹이사슬: 21마디 ‖:, 29마디 1번 괄호, 54마디 끝 :‖, 55마디 2번 괄호.
      final MeasureMap map = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 21),
        ScoreAnchor(
            page: 0,
            y: 0.3,
            measure: 21,
            endMeasure: 29,
            repeatStarts: <int>[0]),
        ScoreAnchor(
            page: 0,
            y: 0.5,
            measure: 29,
            endMeasure: 55,
            firstEndings: <int>[0]),
        ScoreAnchor(
            page: 0,
            y: 0.7,
            measure: 55,
            endMeasure: 57,
            secondEndings: <int>[0]),
      ]);
      expect(map.repeats.single.startMeasure, 21);
      expect(map.playbackBars.map((bar) => bar.physicalMeasure).toList(), <int>[
        for (int m = 1; m <= 54; m++) m,
        for (int m = 21; m <= 28; m++) m,
        55,
        56,
      ]);
    });

    group('D.S.·D.C.·코다', () {
      List<int> order(List<ScoreAnchor> anchors) => MeasureMap(anchors)
          .playbackBars
          .map((bar) => bar.physicalMeasure)
          .toList();

      test('D.S. al Coda는 세뇨로 돌아가 To Coda에서 코다로 뛴다', () {
        // 사건의 지평선 모양: 3마디 세뇨, 4마디 끝 To Coda, 6마디 끝 D.S., 7마디 코다.
        expect(
          order(const <ScoreAnchor>[
            ScoreAnchor(
                page: 0,
                y: 0.2,
                measure: 1,
                endMeasure: 5,
                navigation: <String, List<int>>{
                  ScoreAnchor.segno: <int>[2],
                  ScoreAnchor.toCoda: <int>[4],
                }),
            ScoreAnchor(
                page: 0,
                y: 0.4,
                measure: 5,
                endMeasure: 7,
                navigation: <String, List<int>>{
                  ScoreAnchor.dalSegno: <int>[2],
                }),
            ScoreAnchor(
                page: 0,
                y: 0.6,
                measure: 7,
                endMeasure: 9,
                navigation: <String, List<int>>{
                  ScoreAnchor.coda: <int>[0],
                }),
          ]),
          <int>[1, 2, 3, 4, 5, 6, 3, 4, 7, 8],
        );
      });

      test('D.S. 뒤에는 도돌이를 다시 돌지 않고 1번 괄호를 건너뛴다', () {
        expect(
          order(const <ScoreAnchor>[
            ScoreAnchor(
                page: 0,
                y: 0.2,
                measure: 1,
                endMeasure: 5,
                repeatStarts: <int>[
                  1
                ],
                navigation: <String, List<int>>{
                  ScoreAnchor.segno: <int>[1]
                }),
            ScoreAnchor(
                page: 0,
                y: 0.4,
                measure: 5,
                endMeasure: 9,
                repeatEnds: <int>[
                  1
                ],
                firstEndings: <int>[
                  0
                ],
                secondEndings: <int>[
                  1
                ],
                navigation: <String, List<int>>{
                  ScoreAnchor.dalSegno: <int>[2]
                }),
            ScoreAnchor(page: 0, y: 0.6, measure: 9, endMeasure: 11),
          ]),
          <int>[1, 2, 3, 4, 5, 2, 3, 4, 6, 2, 3, 4, 6, 7, 8, 9, 10],
        );
      });

      test('D.C. al Fine은 처음으로 돌아가 Fine에서 멈춘다', () {
        expect(
          order(const <ScoreAnchor>[
            ScoreAnchor(
                page: 0,
                y: 0.2,
                measure: 1,
                endMeasure: 5,
                navigation: <String, List<int>>{
                  ScoreAnchor.fine: <int>[3]
                }),
            ScoreAnchor(
                page: 0,
                y: 0.4,
                measure: 5,
                endMeasure: 7,
                navigation: <String, List<int>>{
                  ScoreAnchor.daCapo: <int>[2]
                }),
          ]),
          <int>[1, 2, 3, 4, 5, 6, 1, 2, 3],
        );
      });

      test('D.S.가 없으면 To Coda는 무시한다', () {
        expect(
          order(const <ScoreAnchor>[
            ScoreAnchor(
                page: 0,
                y: 0.2,
                measure: 1,
                endMeasure: 5,
                navigation: <String, List<int>>{
                  ScoreAnchor.toCoda: <int>[2]
                }),
          ]),
          <int>[1, 2, 3, 4],
        );
      });

      test('이동 기호는 JSON으로 보존한다', () {
        const ScoreAnchor anchor = ScoreAnchor(
            page: 0,
            y: 0.2,
            measure: 1,
            navigation: <String, List<int>>{
              ScoreAnchor.dalSegno: <int>[4]
            });
        expect(
            ScoreAnchor.fromJson(anchor.toJson()).navigation,
            <String, List<int>>{
              ScoreAnchor.dalSegno: <int>[4]
            });
      });
    });

    test('반복을 풀어 쓴 악보와 연주 순서 인덱스로 동기화한다', () {
      final MeasureMap compact = repeated();
      final MeasureMap expanded = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.2, measure: 1, endMeasure: 21),
      ]);
      final PlaybackPosition secondPass = compact.playbackPositionAt(
        0,
        0.1,
        0.25,
        currentTimeline: 0,
      )!;
      expect(secondPass.timeline, closeTo(8.4, 1e-9));
      expect(expanded.bandOfPlayback(secondPass.timeline)!.startMeasure, 1);
      expect(expanded.playbackBarAt(secondPass.timeline)!.physicalMeasure, 9);
    });

    test('키보드 5~35마디 반복은 드럼 36마디와 키보드 5마디를 잇는다', () {
      final MeasureMap compactKeyboard = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 5),
        ScoreAnchor(
          page: 0,
          y: 0.3,
          measure: 5,
          endMeasure: 36,
          repeatStarts: <int>[0],
          repeatEnds: <int>[31],
        ),
        ScoreAnchor(page: 0, y: 0.5, measure: 36, endMeasure: 80),
      ]);
      final MeasureMap expandedDrum = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 80),
      ]);

      expect(compactKeyboard.repeats.single.startMeasure, 5);
      expect(compactKeyboard.repeats.single.endMeasure, 36);
      expect(compactKeyboard.playbackBars[35].physicalMeasure, 5);
      expect(expandedDrum.playbackBars[35].physicalMeasure, 36);
      expect(
        compactKeyboard.bandOfPlayback(35)!.startMeasure,
        5,
      );
    });

    test('키보드 5마디에서 원래 위치와 도돌이 후 위치를 모두 제시한다', () {
      final MeasureMap map = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 5),
        ScoreAnchor(
          page: 0,
          y: 0.3,
          measure: 5,
          endMeasure: 36,
          xStart: 0.1,
          xEnd: 0.9,
          repeatStarts: <int>[0],
          repeatEnds: <int>[31],
        ),
        ScoreAnchor(page: 0, y: 0.5, measure: 36, endMeasure: 80),
      ]);

      final List<PlaybackPosition> positions =
          map.playbackPositionsAt(0, 0.1, 0.35);
      expect(positions, hasLength(2));
      expect(positions[0].timeline.floor() + 1, 5);
      expect(positions[1].timeline.floor() + 1, 36);
      expect(positions[0].physicalMeasure.floor(), 5);
      expect(positions[1].physicalMeasure.floor(), 5);
    });

    test('1·2번 엔딩이 확인되면 32마디보다 긴 처음부터의 반복을 허용한다', () {
      final MeasureMap map = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 0,
          y: 0.1,
          measure: 1,
          endMeasure: 77,
          repeatStarts: <int>[24, 48], // 이미지 오검출 후보
          repeatEnds: <int>[4, 8, 12],
        ),
        ScoreAnchor(
          page: 1,
          y: 0.1,
          measure: 77,
          endMeasure: 97,
          repeatEnds: <int>[20],
          firstEndings: <int>[0],
        ),
        ScoreAnchor(
          page: 2,
          y: 0.1,
          measure: 97,
          endMeasure: 109,
          secondEndings: <int>[0],
        ),
      ]);

      expect(map.repeats, hasLength(1));
      expect(map.repeats.single.startMeasure, 1);
      expect(map.repeats.single.endMeasure, 97);
      expect(map.repeats.single.firstEndingStart, 77);
      expect(map.repeats.single.secondEndingStart, 97);
      expect(map.playbackLength, 184);
      expect(map.playbackBars[96].physicalMeasure, 1);
    });

    test('가짜 종료표에 시작표를 빼앗겨도 1·2번 엔딩 반복은 그 시작표로 돌아간다', () {
      // '시간을 달리네': 13마디 ‖: … 1번 괄호 29~32 :‖ 2번 괄호 33.
      // 20마디 끝 겹세로선 옆 점음표가 종료표로 오검출돼 13마디 시작표와
      // 먼저 짝지어지면, 진짜 반복이 곡 처음(1마디)으로 돌아가 버렸다.
      final MeasureMap map = MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(page: 0, y: 0.1, measure: 1, endMeasure: 13),
        ScoreAnchor(
          page: 1,
          y: 0.1,
          measure: 13,
          endMeasure: 21,
          repeatStarts: <int>[0],
          repeatEnds: <int>[8], // 오검출
        ),
        ScoreAnchor(
          page: 2,
          y: 0.1,
          measure: 29,
          endMeasure: 33,
          repeatEnds: <int>[4],
          firstEndings: <int>[0],
        ),
        ScoreAnchor(
          page: 2,
          y: 0.3,
          measure: 33,
          endMeasure: 41,
          secondEndings: <int>[0],
        ),
      ]);

      expect(map.repeats, hasLength(1));
      expect(map.repeats.single.startMeasure, 13);
      expect(map.repeats.single.endMeasure, 33);
      final List<int> order =
          map.playbackBars.map((PlaybackBar b) => b.physicalMeasure).toList();
      expect(order.indexOf(33), 32 + 16); // 1~32, 13~28 다음에 33
      expect(order[32], 13);
    });
  });
}
