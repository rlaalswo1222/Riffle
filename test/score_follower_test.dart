import 'dart:typed_data';

import 'package:barlink/services/chord_chart.dart';
import 'package:barlink/services/chroma_stream.dart';
import 'package:barlink/services/score_follower.dart';
import 'package:flutter_test/flutter_test.dart';

/// 악보대로 정확히 연주한 소리(코드 템플릿 그대로)를 [seconds]초 동안 넣고,
/// 마지막에 따라간 위치와 실제 위치(연주 순서 마디, 0부터)를 돌려준다.
(double, double) _play(ChordChart chart, List<int> path, double bpm, double seconds) {
  final ScoreFollower follower = ScoreFollower(chart: chart, path: path, bpm: bpm);
  const double dt = ChromaStream.frameSeconds;
  final Float64List silence = Float64List(12)..fillRange(0, 12, 1 / 3.4641);
  double t = 0, beat = 0;
  FollowState? last;
  // 처음 2초는 조용하다가 연주를 시작한다.
  for (; t < 2; t += dt) {
    last = follower.add(AudioFrame(t, silence, -70));
  }
  for (; t < 2 + seconds; t += dt) {
    final int index = (beat ~/ 4).clamp(0, path.length - 1);
    final int id = chart.templateAt(path[index], beat.floor() % 4);
    last = follower.add(AudioFrame(t, id < 0 ? silence : chart.templates[id], -12));
    beat += bpm / 60 * chart.rateAt(path[index]) * dt;
  }
  return (last!.timeline ?? -1, beat / 4);
}

void main() {
  test('화음이 오래 안 바뀌어도 뒤처지지 않는다', () {
    // 먹이사슬 37~44마디처럼 같은 코드가 8마디 넘게 이어진다.
    final ChordChart chart = ChordChart.fromMeasureChords(
      <int, List<String>>{
        for (int m = 1; m <= 4; m++) m: <String>['A7', 'D7'],
        for (int m = 5; m <= 20; m++) m: <String>['A7'],
      },
      20,
      bpm: 106,
    );
    final List<int> path = <int>[for (int m = 1; m <= 20; m++) m];
    final (double shown, double truth) = _play(chart, path, 106, 30);
    expect(shown, closeTo(truth, 1.0));
  });

  test('곡 중간에 템포가 두 배 가까이 빨라져도 따라간다', () {
    // 먹이사슬 68마디부터 ♩=106 → ♩=196.
    final ChordChart base = ChordChart.fromMeasureChords(
      <int, List<String>>{
        for (int m = 1; m <= 40; m++) m: <String>[m.isEven ? 'G' : 'A', m % 3 == 0 ? 'D' : 'E'],
      },
      40,
      bpm: 106,
    );
    final ChordChart chart = ChordChart(
      beatTemplates: base.beatTemplates,
      templates: base.templates,
      names: base.names,
      measuresWithSymbols: base.measuresWithSymbols,
      printedBpm: 106,
      tempoChanges: const <int, double>{17: 196},
    );
    expect(chart.tempoAt(16), 106);
    expect(chart.tempoAt(17), 196);
    final List<int> path = <int>[for (int m = 1; m <= 40; m++) m];
    // 16마디(약 36초) 뒤 빠른 구간을 10초 더 연주한다.
    final (double shown, double truth) = _play(chart, path, 106, 46);
    expect(truth, greaterThan(20));
    expect(shown, closeTo(truth, 1.0));
  });
}
