import 'dart:convert';
import 'dart:io';

import 'package:barlink/models/measure_map.dart';
import 'package:barlink/models/score_anchor.dart';
import 'package:barlink/services/chord_chart.dart';
import 'package:barlink/services/score_analysis_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ScoreAnalysisCache cache;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('score-analysis-test-');
    cache = ScoreAnalysisCache(directory);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('재실행 후에는 PDF를 분석하지 않고 마디·반복·코드 기준을 복원한다', () async {
    int analyses = 0;
    final original = _score();
    final first =
        await cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
      analyses++;
      return original;
    });
    final reopened = await ScoreAnalysisCache(directory).getOrAnalyze(
      'score',
      pagesCount: 2,
      analyze: () async {
        analyses++;
        throw StateError('저장본을 여는 동안 분석하면 안 된다.');
      },
    );

    expect(analyses, 1);
    expect(reopened.title, first.title);
    expect(reopened.artist, first.artist);
    expect(reopened.map.anchors.map((anchor) => anchor.toJson()).toList(),
        first.map.anchors.map((anchor) => anchor.toJson()).toList());
    expect(
        reopened.map.playbackBars
            .map((bar) => (bar.physicalMeasure, bar.repeatPass))
            .toList(),
        first.map.playbackBars
            .map((bar) => (bar.physicalMeasure, bar.repeatPass))
            .toList());
    expect(reopened.map.hasRepeats, isTrue);
    expect(
        reopened.map.playbackLength, greaterThan(original.chart.measureCount));
    expect(reopened.map.bandOf(3.5)!.x, first.map.bandOf(3.5)!.x);
    expect(reopened.chart.beatTemplates, first.chart.beatTemplates);
    expect(reopened.chart.templates, first.chart.templates);
    expect(reopened.chart.names, first.chart.names);
    expect(reopened.chart.measuresWithSymbols, first.chart.measuresWithSymbols);
    expect(reopened.chart.printedBpm, 148);
  });

  test('버전·악보 키·페이지 수가 다르면 다시 분석하고 새 저장본을 쓴다', () async {
    final file = File('${directory.path}/score.json');
    for (final change in <Map<String, Object>>[
      <String, Object>{'version': ScoreAnalysisCache.version + 1},
      <String, Object>{'key': 'different-score'},
      <String, Object>{'pages_count': 3},
    ]) {
      await cache.save('score', _score(), pagesCount: 2);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      json.addAll(change);
      await file.writeAsString(jsonEncode(json));
      int analyses = 0;
      await cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
        analyses++;
        return _score();
      });
      expect(analyses, 1);
      expect(await cache.load('score', pagesCount: 2), isNotNull);
    }
  });

  test('잘린 저장 파일은 다시 분석해서 복구한다', () async {
    await File('${directory.path}/score.json').writeAsString('{"version":');
    int analyses = 0;
    await cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
      analyses++;
      return _score();
    });
    await cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
      throw StateError('복구한 캐시를 재사용해야 한다.');
    });
    expect(analyses, 1);
  });

  test('유효한 JSON이어도 잘못된 코드 번호·벡터·페이지 위치는 사용하지 않는다', () async {
    final file = File('${directory.path}/score.json');
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (json) => (json['chart']['beat_templates'] as List<dynamic>)[0] = 999,
      (json) => (json['chart']['templates'] as List<dynamic>)[0] = <double>[1],
      (json) => json['anchors'][0]['page'] = 99,
    ]) {
      await cache.save('score', _score(), pagesCount: 2);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      mutate(json);
      await file.writeAsString(jsonEncode(json));
      expect(await cache.load('score', pagesCount: 2), isNull);
    }
  });

  test('분석 실패를 저장하지 않고 다음 열기에서 재시도한다', () async {
    await expectLater(
      cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
        throw StateError('읽을 수 없는 PDF');
      }),
      throwsStateError,
    );
    expect(await File('${directory.path}/score.json').exists(), isFalse);
    expect(
        await cache.getOrAnalyze('score',
            pagesCount: 2, analyze: () async => _score()),
        isA<CachedScoreAnalysis>());
  });

  test('캐시를 저장하지 못해도 현재 분석 결과로 진행한다', () async {
    final blocked = File('${directory.path}/not-a-directory');
    await blocked.writeAsString('occupied');
    final unavailable = ScoreAnalysisCache(Directory(blocked.path));
    final result = _score();
    expect(
        await unavailable.getOrAnalyze('score',
            pagesCount: 2, analyze: () async => result),
        same(result));
    expect(await unavailable.load('score', pagesCount: 2), isNull);
  });

  test('악보 삭제 시 분석 캐시와 임시 파일을 함께 지운다', () async {
    await cache.save('score', _score(), pagesCount: 2);
    await File('${directory.path}/score.json.tmp').writeAsString('pending');
    await cache.remove('score');
    expect(await File('${directory.path}/score.json').exists(), isFalse);
    expect(await File('${directory.path}/score.json.tmp').exists(), isFalse);
    int analyses = 0;
    await cache.getOrAnalyze('score', pagesCount: 2, analyze: () async {
      analyses++;
      return _score();
    });
    expect(analyses, 1);
  });
}

CachedScoreAnalysis _score() => CachedScoreAnalysis(
      title: '테스트 곡',
      artist: '테스트 밴드',
      map: MeasureMap(const <ScoreAnchor>[
        ScoreAnchor(
          page: 0,
          y: 0.2,
          measure: 1,
          endMeasure: 5,
          xStart: 0.1,
          xEnd: 0.9,
          systemBottom: 0.4,
          barlines: <double>[0.1, 0.2, 0.4, 0.7, 0.9],
          repeatStarts: <int>[0],
          firstEndings: <int>[3],
          navigation: <String, List<int>>{
            ScoreAnchor.segno: <int>[0]
          },
        ),
        ScoreAnchor(
          page: 0,
          y: 0.6,
          measure: 5,
          endMeasure: 9,
          repeatEnds: <int>[0],
          secondEndings: <int>[0],
          navigation: <String, List<int>>{
            ScoreAnchor.toCoda: <int>[4]
          },
        ),
        ScoreAnchor(
          page: 1,
          y: 0.2,
          measure: 9,
          endMeasure: 13,
          navigation: <String, List<int>>{
            ScoreAnchor.dalSegno: <int>[4],
            ScoreAnchor.coda: <int>[0],
          },
        ),
      ]),
      chart: ChordChart.fromMeasureChords(
        <int, List<String>>{
          1: <String>['Am'],
          5: <String>['E/G#'],
          9: <String>['Am', 'E/G#']
        },
        12,
        bpm: 148,
      ),
    );
