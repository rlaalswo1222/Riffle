import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import 'chord_chart.dart';

/// 연주 준비에 필요한 PDF 분석 결과. 원곡 기준과 사용자 BPM은 별도 보관한다.
class CachedScoreAnalysis {
  final String title;
  final String artist;
  final MeasureMap map;
  final ChordChart chart;

  const CachedScoreAnalysis({
    required this.title,
    required this.artist,
    required this.map,
    required this.chart,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'artist': artist,
        'anchors': map.anchors.map((anchor) => anchor.toJson()).toList(),
        'chart': <String, dynamic>{
          'beat_templates': chart.beatTemplates.toList(),
          'templates':
              chart.templates.map((template) => template.toList()).toList(),
          'names': chart.names,
          'measures_with_symbols': chart.measuresWithSymbols,
          'printed_bpm': chart.printedBpm,
          'tempo_changes': <String, double>{
            for (final MapEntry<int, double> e in chart.tempoChanges.entries)
              '${e.key}': e.value,
          },
        },
      };

  factory CachedScoreAnalysis.fromJson(Map<String, dynamic> json) {
    final chart = json['chart'] as Map<String, dynamic>;
    return CachedScoreAnalysis(
      title: json['title'] as String,
      artist: json['artist'] as String,
      map: MeasureMap((json['anchors'] as List<dynamic>)
          .map((anchor) => ScoreAnchor.fromJson(anchor as Map<String, dynamic>))
          .toList()),
      chart: ChordChart(
        beatTemplates: Int32List.fromList(
            (chart['beat_templates'] as List<dynamic>).cast<int>()),
        templates: (chart['templates'] as List<dynamic>)
            .map((template) => Float64List.fromList((template as List<dynamic>)
                .map((value) => (value as num).toDouble())
                .toList()))
            .toList(),
        names: List<String>.from(chart['names'] as List<dynamic>),
        measuresWithSymbols: chart['measures_with_symbols'] as int,
        printedBpm: (chart['printed_bpm'] as num?)?.toDouble(),
        tempoChanges: <int, double>{
          for (final MapEntry<String, dynamic> e
              in ((chart['tempo_changes'] as Map<String, dynamic>?) ?? const <String, dynamic>{})
                  .entries)
            int.parse(e.key): (e.value as num).toDouble(),
        },
      ),
    );
  }

  bool isValidFor(int pagesCount) {
    if (map.length < 2 ||
        map.playbackLength == 0 ||
        chart.measureCount == 0 ||
        chart.beatTemplates.length % ChordChart.beatsPerMeasure != 0 ||
        chart.names.length != chart.templates.length ||
        chart.measuresWithSymbols < 0 ||
        chart.measuresWithSymbols > chart.measureCount) {
      return false;
    }
    if (chart.printedBpm != null &&
        (!chart.printedBpm!.isFinite || chart.printedBpm! <= 0)) {
      return false;
    }
    for (final anchor in map.anchors) {
      if (anchor.page < 0 ||
          anchor.page >= pagesCount ||
          !anchor.measure.isFinite ||
          anchor.measure < 1 ||
          !anchor.y.isFinite ||
          anchor.y < 0 ||
          anchor.y > 1 ||
          !anchor.xStart.isFinite ||
          !anchor.xEnd.isFinite ||
          anchor.xStart < 0 ||
          anchor.xStart >= anchor.xEnd ||
          anchor.xEnd > 1 ||
          (anchor.endMeasure != null &&
              (!anchor.endMeasure!.isFinite ||
                  anchor.endMeasure! <= anchor.measure))) {
        return false;
      }
      double previous = -1;
      for (final boundary in anchor.barlines) {
        if (!boundary.isFinite ||
            boundary < 0 ||
            boundary > 1 ||
            boundary <= previous) {
          return false;
        }
        previous = boundary;
      }
    }
    for (final template in chart.templates) {
      if (template.length != 12 || template.any((value) => !value.isFinite)) {
        return false;
      }
    }
    return chart.beatTemplates
        .every((id) => id >= -1 && id < chart.templates.length);
  }
}

/// PDF 바이트로 만든 악보 키별 영구 캐시. 캐시 문제는 PDF 분석으로 복구한다.
class ScoreAnalysisCache {
  // PDF 분석·코드 추출·연주 순서 계산이 바뀌면 올려서 기존 결과를 갱신한다.
  static const int version = 5;

  final Directory directory;

  const ScoreAnalysisCache(this.directory);

  File _file(String key) => File('${directory.path}/$key.json');

  Future<CachedScoreAnalysis?> load(String key,
      {required int pagesCount}) async {
    try {
      final json =
          jsonDecode(await _file(key).readAsString()) as Map<String, dynamic>;
      if (json['version'] != version ||
          json['key'] != key ||
          json['pages_count'] != pagesCount) {
        return null;
      }
      final result = CachedScoreAnalysis.fromJson(json);
      return result.isValidFor(pagesCount) ? result : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String key, CachedScoreAnalysis result,
      {required int pagesCount}) async {
    try {
      if (!result.isValidFor(pagesCount)) return;
      await directory.create(recursive: true);
      final file = _file(key);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(
          jsonEncode(<String, dynamic>{
            'version': version,
            'key': key,
            'pages_count': pagesCount,
            ...result.toJson(),
          }),
          flush: true);
      await pending.rename(file.path);
    } catch (_) {
      // 저장 공간 문제로 캐시를 못 써도 이번 연주는 분석 결과로 진행한다.
    }
  }

  Future<CachedScoreAnalysis> getOrAnalyze(
    String key, {
    required int pagesCount,
    required Future<CachedScoreAnalysis> Function() analyze,
  }) async {
    final saved = await load(key, pagesCount: pagesCount);
    if (saved != null) return saved;
    final result = await analyze();
    await save(key, result, pagesCount: pagesCount);
    return result;
  }

  Future<void> remove(String key) async {
    for (final file in <File>[_file(key), File('${_file(key).path}.tmp')]) {
      if (await file.exists()) await file.delete();
    }
  }
}
