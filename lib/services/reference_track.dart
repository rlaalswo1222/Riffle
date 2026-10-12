import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'chord_chart.dart';
import 'chroma_stream.dart';

/// 원곡 음원을 악보의 연주 순서에 맞춰 둔 기준 소리.
///
/// 코드 심볼은 "이 박에 A코드" 정도만 알려 준다. 원곡에는 멜로디·베이스·
/// 리듬이 다 들어 있어서, 라이브 소리를 원곡과 대조하면 마디 안 위치와
/// 반복 구간을 훨씬 잘 구분한다(노불달 합주 녹음: 정확한 마디 75% → 85%).
///
/// 만드는 순서
///  1. 원곡을 실시간과 똑같은 방식(ChromaStream)으로 12음 크로마로 바꾼다.
///  2. 키 차이를 판정한다(밴드가 원곡과 다른 키로 칠 수 있다).
///  3. 원곡과 악보 코드를 DTW로 정렬해 연주 순서의 마디마다 원곡 시각을 얻는다.
///  4. 튀는 마디를 주변 템포로 다듬는다.
///  5. 연주 순서의 16분음표마다 그 시각의 원곡 크로마를 기준으로 뽑는다.
class ReferenceTrack {
  /// 한 박을 몇 칸으로 나누나. 4면 16분음표.
  final int res;

  /// 연주 순서 (마디 × 4박 × [res]) 칸마다의 기준 크로마(L2 정규화, 악보 키).
  final List<Float64List> templates;

  /// 연주 순서 i번째 마디가 원곡에서 시작하는 시각(초). 길이는 마디 수 + 1.
  final List<double> measureTimes;

  /// 원곡이 악보보다 몇 반음 높은가. 기준 크로마는 악보 키로 되돌려 둔다.
  final int keyShift;

  /// 다듬기 전 정렬이 다듬은 결과와 0.5초 안에서 맞은 마디 비율. 정렬 품질.
  final double fit;

  const ReferenceTrack({
    required this.res,
    required this.templates,
    required this.measureTimes,
    required this.keyShift,
    required this.fit,
  });

  static const int _beats = ChordChart.beatsPerMeasure;
  static const int _group = 4; // 정렬은 프레임 4개(약 0.19초)씩 묶어서 한다

  /// [samples]: 원곡, 22050Hz 모노, -1~1. [path]: 연주 순서(인쇄 마디 번호).
  static ReferenceTrack build(
    Float64List samples,
    ChordChart chart,
    List<int> path,
    double bpm, {
    int res = 4,
  }) {
    // 1. 실시간과 같은 특징
    final List<AudioFrame> frames = ChromaStream().addSamples(samples);
    if (frames.length < 100) {
      throw StateError('원곡이 너무 짧습니다.');
    }
    double loudest = -200;
    for (final AudioFrame f in frames) {
      if (f.db > loudest) loudest = f.db;
    }
    int start = 0, end = frames.length - 1;
    while (start < end && frames[start].db < loudest - 35) {
      start++;
    }
    while (end > start && frames[end].db < loudest - 35) {
      end--;
    }

    // 정렬용으로 4프레임씩 평균
    final List<Float64List> audio = <Float64List>[];
    final List<double> audioTime = <double>[];
    for (int i = start; i + _group <= end + 1; i += _group) {
      final Float64List v = Float64List(12);
      for (int k = 0; k < _group; k++) {
        for (int p = 0; p < 12; p++) {
          v[p] += frames[i + k].chroma[p];
        }
      }
      audio.add(_normalized(v));
      audioTime.add(frames[i].time);
    }

    // 악보: 연주 순서의 박마다 코드 템플릿을 표기 템포로 펼친다. 곡 중간에
    // 템포가 바뀌면(♩=106 → 196) 그 마디부터 그 템포로 펼친다.
    const double groupSeconds = _group * ChromaStream.frameSeconds;
    final Float64List uniform = Float64List(12)..fillRange(0, 12, 1 / math.sqrt(12));
    final List<Float64List> score = <Float64List>[];
    final List<int> measureStart = <int>[]; // 연주 순서 마디 → score 시작 칸
    for (final int measure in path) {
      measureStart.add(score.length);
      final int perBeat =
          math.max(1, (60 / (bpm * chart.rateAt(measure)) / groupSeconds).round());
      for (int b = 0; b < _beats; b++) {
        final int id = chart.templateAt(measure, b);
        final Float64List v = id < 0 ? uniform : chart.templates[id];
        for (int k = 0; k < perBeat; k++) {
          score.add(v);
        }
      }
    }

    // 2. 키 차이: 원곡 전체 평균 크로마와 악보 평균을 12가지로 돌려 비교
    final Float64List meanAudio = Float64List(12), meanScore = Float64List(12);
    for (final Float64List v in audio) {
      for (int p = 0; p < 12; p++) {
        meanAudio[p] += v[p];
      }
    }
    for (final Float64List v in score) {
      for (int p = 0; p < 12; p++) {
        meanScore[p] += v[p];
      }
    }
    int shift = 0;
    double best = -1;
    for (int s = 0; s < 12; s++) {
      double c = 0;
      for (int p = 0; p < 12; p++) {
        c += meanAudio[(p + s) % 12] * meanScore[p];
      }
      if (c > best) {
        best = c;
        shift = s;
      }
    }
    if (shift > 6) shift -= 12;
    final List<Float64List> scoreShifted = shift == 0
        ? score
        : <Float64List>[for (final Float64List v in score) _rolled(v, -shift)];

    // 3. DTW
    final (List<int> firstAudioOfScore, int endAudio) = _dtw(scoreShifted, audio);
    final int n = path.length;
    final List<double> raw = List<double>.filled(n + 1, 0);
    for (int i = 0; i < n; i++) {
      raw[i] = audioTime[firstAudioOfScore[measureStart[i]]];
    }
    raw[n] = audioTime[endAudio] + groupSeconds;

    // 4. 다듬기: 각 마디 시작을 앞뒤 8마디의 흐름(Theil–Sen 직선)으로 다시
    //    잡는다. DTW는 프레임 단위로 계단지게 붙어서 마디 몇 개가 반 마디씩
    //    튀는데, 같은 4마디가 반복되는 구간에서는 그 정도로도 엉뚱한 반복에
    //    붙는다. 템포가 바뀌는 곡도 8마디 안에서는 거의 직선이다.
    final List<double> times = List<double>.filled(n + 1, 0);
    int within = 0;
    // 클릭에 맞춰 녹음한 스튜디오 음원은 곡 전체가 템포 하나로 설명된다. 그러면
    // 그 직선을 그대로 쓴다. 같은 4마디가 반복되는 구간처럼 DTW가 흔들리는
    // 곳까지 바로잡힌다(노불달 '오 오 오' 구간).
    final (double gSlope, double gCut) = _theilSen(raw, 0, n);
    int globalWithin = 0;
    for (int i = 0; i <= n; i++) {
      if ((gCut + gSlope * i - raw[i]).abs() < 0.5) globalWithin++;
    }
    final bool constantTempo = globalWithin >= 0.9 * (n + 1);
    for (int i = 0; i <= n; i++) {
      if (constantTempo) {
        times[i] = gCut + gSlope * i;
        if ((times[i] - raw[i]).abs() < 0.5) within++;
        continue;
      }
      // 템포 표시가 바뀌는 곳을 넘어가면 직선이 아니다. 같은 템포 구간 안에서만 본다.
      double rateOf(int k) => chart.rateAt(path[math.min(k, n - 1)]);
      final double here = rateOf(i);
      int lo = i, hi = i;
      while (lo > math.max(0, i - 8) && rateOf(lo - 1) == here) {
        lo--;
      }
      while (hi < math.min(n, i + 8) && rateOf(hi + 1) == here) {
        hi++;
      }
      final List<double> slopes = <double>[];
      for (int a = lo; a <= hi; a++) {
        for (int b = a + 1; b <= hi; b++) {
          slopes.add((raw[b] - raw[a]) / (b - a));
        }
      }
      final double slope = slopes.isEmpty ? 0 : _median(slopes);
      times[i] = _median(<double>[for (int k = lo; k <= hi; k++) raw[k] + slope * (i - k)]);
      if ((times[i] - raw[i]).abs() < 0.5) within++;
    }

    // 5. 16분음표마다 원곡 크로마 (악보 키로 되돌림)
    final List<double> frameTimes = <double>[for (final AudioFrame f in frames) f.time];
    final int cells = _beats * res;
    final List<Float64List> templates = <Float64List>[];
    for (int i = 0; i < n; i++) {
      for (int q = 0; q < cells; q++) {
        final double t = times[i] + (times[i + 1] - times[i]) * q / cells;
        final int f = _nearest(frameTimes, t);
        templates.add(_rolled(frames[f].chroma, shift));
      }
    }

    return ReferenceTrack(
      res: res,
      templates: templates,
      measureTimes: times,
      keyShift: shift,
      fit: within / (n + 1),
    );
  }

  /// 악보 프레임 i가 처음 맞닿는 원곡 프레임 번호와, 악보가 끝나는 원곡 프레임.
  ///
  /// 악보의 끝은 원곡의 끝에 묶지 않는다. 원곡은 마지막 화음을 길게 끌거나
  /// 잔향·페이드아웃이 이어지는 일이 많아서, 묶으면 그 몇 초가 마지막 몇 줄에
  /// 나뉘어 들어가 정렬이 밀린다(노불달: 마지막 15마디가 4~7초 밀림).
  static (List<int>, int) _dtw(List<Float64List> x, List<Float64List> y) {
    final int n = x.length, m = y.length;
    final Float32List d = Float32List(n * m);
    final Uint8List step = Uint8List(n * m); // 0 대각, 1 위(악보만 진행), 2 왼쪽(원곡만)
    for (int i = 0; i < n; i++) {
      final Float64List xi = x[i];
      for (int j = 0; j < m; j++) {
        final Float64List yj = y[j];
        double dot = 0;
        for (int p = 0; p < 12; p++) {
          dot += xi[p] * yj[p];
        }
        final double cost = 1 - dot;
        final int at = i * m + j;
        if (i == 0 && j == 0) {
          d[at] = cost;
          continue;
        }
        double bestPrev = double.infinity;
        int s = 0;
        if (i > 0 && j > 0 && d[at - m - 1] < bestPrev) {
          bestPrev = d[at - m - 1];
          s = 0;
        }
        if (i > 0 && d[at - m] + 0.25 < bestPrev) {
          bestPrev = d[at - m] + 0.25;
          s = 1;
        }
        if (j > 0 && d[at - 1] + 0.25 < bestPrev) {
          bestPrev = d[at - 1] + 0.25;
          s = 2;
        }
        d[at] = bestPrev + cost;
        step[at] = s;
      }
    }
    int end = m - 1;
    for (int j = m ~/ 2; j < m; j++) {
      if (d[(n - 1) * m + j] < d[(n - 1) * m + end]) end = j;
    }
    final List<int> first = List<int>.filled(n, end);
    int i = n - 1, j = end;
    while (true) {
      first[i] = j; // 거꾸로 가므로 마지막에 남는 값이 가장 이른 원곡 프레임
      if (i == 0 && j == 0) break;
      final int s = step[i * m + j];
      if (i == 0) {
        j--;
      } else if (j == 0) {
        i--;
      } else if (s == 0) {
        i--;
        j--;
      } else if (s == 1) {
        i--;
      } else {
        j--;
      }
    }
    return (first, end);
  }

  static Float64List _normalized(Float64List v) {
    double s = 0;
    for (final double x in v) {
      s += x * x;
    }
    s = math.sqrt(s) + 1e-9;
    return Float64List.fromList(<double>[for (final double x in v) x / s]);
  }

  /// [shift]만큼 반음 올린 벡터: 결과[p] = v[(p + shift) mod 12].
  static Float64List _rolled(Float64List v, int shift) => Float64List.fromList(
      <double>[for (int p = 0; p < 12; p++) v[(p + shift + 1200) % 12]]);

  /// 점 (k, v[k]) k∈[lo,hi]에 맞춘 Theil–Sen 직선 (기울기, 절편).
  static (double, double) _theilSen(List<double> v, int lo, int hi) {
    final List<double> slopes = <double>[];
    final int stride = math.max(1, (hi - lo) ~/ 120); // 점이 많으면 건너뛰며 짝짓는다
    for (int a = lo; a <= hi; a += stride) {
      for (int b = a + stride; b <= hi; b += stride) {
        slopes.add((v[b] - v[a]) / (b - a));
      }
    }
    final double slope = slopes.isEmpty ? 0 : _median(slopes);
    return (slope, _median(<double>[for (int k = lo; k <= hi; k++) v[k] - slope * k]));
  }

  static double _median(List<double> v) {
    final List<double> s = <double>[...v]..sort();
    return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
  }

  static int _nearest(List<double> sorted, double t) {
    int lo = 0, hi = sorted.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (sorted[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (t - sorted[lo - 1]).abs() < (sorted[lo] - t).abs()) return lo - 1;
    return lo;
  }

  // ---------------------------------------------------------------- 저장
  /// 기준 크로마는 float32 묶음으로, 나머지는 JSON으로 저장한다.
  Uint8List encodeTemplates() {
    final Float32List all = Float32List(templates.length * 12);
    for (int i = 0; i < templates.length; i++) {
      for (int p = 0; p < 12; p++) {
        all[i * 12 + p] = templates[i][p];
      }
    }
    return all.buffer.asUint8List();
  }

  String encodeMeta(Map<String, dynamic> extra) => jsonEncode(<String, dynamic>{
        ...extra,
        'res': res,
        'key_shift': keyShift,
        'fit': fit,
        'measure_times': measureTimes,
      });

  static ReferenceTrack decode(Uint8List templateBytes, String meta) {
    final Map<String, dynamic> json = jsonDecode(meta) as Map<String, dynamic>;
    final Float32List all = templateBytes.buffer.asFloat32List(
        templateBytes.offsetInBytes, templateBytes.lengthInBytes ~/ 4);
    return ReferenceTrack(
      res: (json['res'] as num).toInt(),
      templates: <Float64List>[
        for (int i = 0; i < all.length ~/ 12; i++)
          Float64List.fromList(all.sublist(i * 12, i * 12 + 12)),
      ],
      measureTimes: (json['measure_times'] as List<dynamic>)
          .map((dynamic v) => (v as num).toDouble())
          .toList(),
      keyShift: (json['key_shift'] as num).toInt(),
      fit: (json['fit'] as num).toDouble(),
    );
  }
}
