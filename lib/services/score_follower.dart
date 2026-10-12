import 'dart:math' as math;
import 'dart:typed_data';

import 'chord_chart.dart';
import 'chroma_stream.dart';
import 'reference_track.dart';

enum FollowMode {
  /// 연주가 없다. 소리가 나기를 기다린다.
  waiting,

  /// 소리는 나는데 아직 악보 어디인지 확정하지 못했다.
  searching,

  /// 위치를 잡고 따라가는 중.
  tracking,
}

class FollowState {
  final FollowMode mode;

  /// 연주 순서([MeasureMap.playbackBars]) 위의 위치. 정수부가 몇 번째 마디,
  /// 소수부가 마디 안 진행률이다. 위치를 모르면 null.
  final double? timeline;

  /// [timeline]이 아직 소리로 확인되지 않은 추정치인가. 시작 마디를 알 때는
  /// 소리가 나는 순간 그 마디에서 출발하고, 몇 초 뒤 확인되면 false가 된다.
  final bool provisional;

  final double bpm;

  /// 최근 1초 평균 입력 음량과, 이보다 커야 연주로 보는 기준(둘 다 dBFS).
  final double db;
  final double threshold;
  final double time;

  const FollowState(this.mode, this.timeline, this.bpm, this.db,
      this.threshold, this.time, {this.provisional = false});
}

/// 소리를 들으며 악보 위 연주 위치를 따라간다.
///
/// 파이썬 시뮬레이션(노불달 녹음 페이지 정확도 96%)과 같은 규칙이다.
///  - 평소에는 템포로 시계처럼 전진한다.
///  - 1초마다 최근 6초의 소리를 코드 진행과 대조해 위치·템포를 보정한다.
///  - 시작 위치는 곡 전체에서 찾지 않는다. 같은 코드 진행이 반복되는 곡이
///    많아 화성만으로는 어느 반복인지 구분할 수 없기 때문이다. 대신
///    '처음부터' / 사용자가 탭한 마디 / 멈춘 곳 근처에서만 찾는다.
///  - 1초 넘게 조용해도 박자는 계속 간다(브레이크). 최근 3초 중 85% 이상
///    조용하면 멈춘 것으로 본다.
///  - '조용함'의 기준은 고정값이 아니다. 마이크·스피커·방마다 음량이 크게
///    달라서, 배경 소음과 연주 음량 사이의 [split] 지점을 기준으로 삼는다.
///    소리가 작아 둘의 간격이 좁으면 기준 여유도 좁아진다.
class ScoreFollower {
  static const double _dt = ChromaStream.frameSeconds;
  static const int _beats = ChordChart.beatsPerMeasure;

  final ChordChart chart;

  /// 연주 순서대로 늘어놓은 인쇄 마디 번호.
  final List<int> path;

  /// 악보 첫 템포(박/초). 곡 중간에 템포가 바뀌면 [_rate]만큼 곱한다.
  final double nominal;

  /// 연주 순서 마디마다 첫 템포에 대한 빠르기 비율(먹이사슬 68마디부터 196/106).
  late final Float64List _rate;

  /// 배경 소음에서 연주 음량까지의 간격 중 어디를 기준으로 삼을지(0~1).
  /// 여유는 5~12dB로 제한한다.
  final double split;

  /// 이보다 크면 배경 소음과 상관없이 연주로 본다. 녹음을 연주 도중에
  /// 시작해서 배경 소음을 못 잰 경우의 안전장치다.
  static const double _alwaysLoudDb = -25;

  late final Int32List _rows; // 연주 순서 (박 × _res) → 템플릿 번호
  late final List<Float64List> _templates;

  /// 한 박을 몇 칸으로 나눠 대조하나. 코드 기준은 1, 원곡 기준은 4(16분음표).
  late final int _res;
  late final int _totalBeats;

  /// 원곡 기준으로 따라가는가.
  bool get usesReference => _res > 1;

  ScoreFollower({
    required this.chart,
    required this.path,
    required double bpm,
    this.split = 0.35,
    int startIndex = 0,
    ReferenceTrack? reference,
  }) : nominal = bpm / 60 {
    _totalBeats = path.length * _beats;
    if (reference != null && reference.templates.length == _totalBeats * reference.res) {
      // 원곡 기준: 연주 순서의 16분음표마다 원곡의 실제 소리가 기준이 된다.
      _res = reference.res;
      _templates = reference.templates;
      lostAfterLock = 2;
      lostEvery = 0.5;
      lostWindow = 4;
      lostHits = 3;
      lostMargin = 0.02;
      lostDistancePenalty = 0.0005;
      _rows = Int32List.fromList(List<int>.generate(_templates.length, (int i) => i));
    } else {
      _res = 1;
      _templates = chart.templates;
      _rows = Int32List(_totalBeats);
      for (int i = 0; i < path.length; i++) {
        for (int b = 0; b < _beats; b++) {
          _rows[i * _beats + b] = chart.templateAt(path[i], b);
        }
      }
    }
    _rate = Float64List.fromList(<double>[for (final int m in path) chart.rateAt(m)]);
    _startIndex = startIndex;
  }

  int _indexOf(double beat) => (beat ~/ _beats).clamp(0, path.length - 1);

  /// [beat]에서 악보대로라면 박/초.
  double _nominalAt(double beat) => nominal * _rate[_indexOf(beat)];

  /// [from]박에서 [to]박으로 옮길 때 템포에 곱할 값(템포 표시가 바뀌는 곳).
  double _rateChange(double from, double to) => _rate[_indexOf(to)] / _rate[_indexOf(from)];

  // ---- 최근 소리 (최대 12초)
  final List<double> _times = <double>[];
  final List<Float64List> _sims = <Float64List>[]; // 프레임 × 템플릿 유사도
  final List<bool> _loud = <bool>[];
  final List<double> _dbs = <double>[];
  int _base = 0; // 버퍼 맨 앞 프레임의 전체 번호

  FollowMode _mode = FollowMode.waiting;
  int _startIndex = 0;
  int? _tapIndex; // 사용자가 '여기서부터'라고 알려준 마디
  int _locks = 0;
  int? _lastStop;
  int? _holdIndex;
  double _quiet = 0;
  double _onset = 0;
  int _seg = 0;
  (int, double)? _prev;
  double _lastSearch = -1;
  double _lastCorrection = 0;
  double _pos = 0; // 박 단위
  double _tempo = 0;
  double _dbSum = 0;
  double? _floor; // 배경 소음 추정치
  double? _peak; // 연주 음량 추정치
  bool _provisional = false; // 위치를 확인 전에 미리 움직이는 중

  // ---- 갈림길(연주 순서가 건너뛰는 곳)에서 함께 들고 가는 두 번째 가설
  _Hyp? _alt;
  double _mainFork = 0;
  final List<double> _mainRecent = <double>[];
  int _lastIndex = -1;

  // ---- 길 잃음 감지
  double _lockTime = 0;
  double _lastLostCheck = 0;
  (double, double)? _challenger; // (박 위치, 시각)
  int _challengerHits = 0;

  /// 갈림길에서 반대 선택도 같이 추적할지. 끄면 악보에 적힌 순서만 따른다.
  bool branches = true;

  /// 지금 위치가 계속 안 맞으면 근처에서 맞는 위치를 찾아 옮길지.
  bool recover = true;

  FollowMode get mode => _mode;

  /// 녹음 전에 시작 마디(연주 순서 번호)를 정한다.
  void setStart(int index) => _startIndex = index.clamp(0, path.length - 1);

  /// 연주 중 사용자가 마디를 탭했다. 따라가는 중이면 그 마디 처음으로 바로
  /// 옮기고, 아니면 다음에 소리가 날 때 그 마디에서 찾는다.
  void tap(int index) {
    final int i = index.clamp(0, path.length - 1);
    if (_mode == FollowMode.tracking) {
      _tempo *= _rateChange(_pos, i * _beats.toDouble());
      _pos = i * _beats.toDouble();
      _alt = null;
      _lastIndex = i;
      _challenger = null;
      _challengerHits = 0;
    } else {
      _tapIndex = i;
      if (_mode == FollowMode.searching) {
        // 연주 중 탭 = "지금 여기". 확인 전이라도 바로 거기서 출발한다.
        _prev = null;
        _provisional = true;
        _pos = i * _beats.toDouble();
        _tempo = _nominalAt(_pos);
      }
    }
  }

  FollowState add(AudioFrame frame) {
    final double t = frame.time;
    _times.add(t);
    _dbs.add(frame.db);
    _dbSum += frame.db;
    final int win = (1.0 / _dt).round();
    if (_dbs.length > win) _dbSum -= _dbs[_dbs.length - 1 - win];
    final double smooth = _dbSum / math.min(_dbs.length, win);
    // 배경 소음: 지금까지 가장 조용했던 1초. 마이크가 막 켜진 0.5초는 뺀다.
    // 조용한 동안에는 천천히(초당 0.5dB) 따라 올라가 주변이 시끄러워져도 맞춘다.
    // 연주 음량: 가장 컸던 1초. 초당 0.2dB씩 천천히 내려와 바뀐 음량에 맞춘다.
    // 아직 위치를 못 잡았을 때는 연주 음량을 모르므로 여유를 넉넉히(8dB) 둔다.
    // 그러지 않으면 연주 전 잡담을 '연주 시작'으로 착각한다.
    final double minMargin = _locks == 0 ? 8 : 5;
    double margin = minMargin;
    if (t > 0.5 + ChromaStream.fftSize / ChromaStream.sampleRate) {
      _peak = _peak == null || smooth > _peak! ? smooth : _peak! - 0.2 * _dt;
      if (_floor != null) {
        margin = (split * (_peak! - _floor!)).clamp(minMargin, 12.0);
      }
      if (_floor == null || smooth < _floor!) {
        _floor = smooth;
      } else if (smooth < _floor! + margin) {
        _floor = _floor! + 0.5 * _dt;
      }
      if (_peak! < _floor!) _peak = _floor;
    }
    final double threshold =
        math.min((_floor ?? _alwaysLoudDb - margin) + margin, _alwaysLoudDb);
    final bool loud = smooth > threshold;
    _loud.add(loud);
    final Float64List sims = Float64List(_templates.length);
    for (int k = 0; k < sims.length; k++) {
      final Float64List v = _templates[k];
      double s = 0;
      for (int p = 0; p < 12; p++) {
        s += v[p] * frame.chroma[p];
      }
      sims[k] = s;
    }
    _sims.add(sims);
    _trim();
    final int k = _base + _times.length - 1; // 이 프레임의 전체 번호

    // ---- 멈춤 판정
    if (!loud && _quiet == 0 && _mode == FollowMode.tracking) {
      _holdIndex = (_pos ~/ _beats).clamp(0, path.length - 1);
    }
    _quiet = loud ? 0 : _quiet + _dt;
    if (_mode == FollowMode.searching && _quiet > 1.0) {
      _mode = FollowMode.waiting;
      _prev = null;
      _provisional = false;
    }
    if (_mode == FollowMode.tracking && _quietShare(k, 3.0) > 0.85) {
      _lastStop = _holdIndex;
      _mode = FollowMode.waiting;
      _alt = null;
    }

    if (_mode == FollowMode.waiting) {
      if (loud) {
        // 1초 평균은 늦게 반응한다. 실제로 소리가 커진 첫 프레임까지 되짚는다.
        int first = _times.length - 1;
        final int limit = math.max(0, _times.length - (1.5 / _dt).round());
        while (first - 1 >= limit &&
            _dbs[_dbs.length - (_times.length - first) - 1] > threshold - 3) {
          first--;
        }
        _mode = FollowMode.searching;
        _onset = _times[first];
        _seg = _base + first;
        _prev = null;
        _lastSearch = -1;
        // 들어올 마디를 알면(처음 시작·탭) 확인을 기다리지 않고 바로 출발한다.
        final int? known = _tapIndex ?? (_locks == 0 ? _startIndex : null);
        _provisional = known != null;
        if (known != null) {
          _tempo = _nominalAt(known * _beats.toDouble());
          _pos = known * _beats + _tempo * (t - _onset);
        }
      }
    } else if (_mode == FollowMode.searching) {
      if (_provisional) _pos += _nominalAt(_pos) * _dt;
      if (t - _onset >= 2.5 && t - _lastSearch >= 0.5) {
        _lastSearch = t;
        _search(k, t);
      }
    }

    if (_mode == FollowMode.tracking) {
      // 템포 표시가 바뀌는 마디를 지나면 빠르기도 그 비율만큼 바꾼다.
      final double before = _pos;
      _pos += _tempo * _dt;
      _tempo *= _rateChange(before, _pos);
      final _Hyp? alt = _alt;
      if (alt != null) {
        final double from = alt.pos;
        alt.pos += alt.tempo * _dt;
        alt.tempo *= _rateChange(from, alt.pos);
      }
      _maybeFork();
      if (t - _lastCorrection >= 1.0) {
        _lastCorrection = t;
        _correct(k, t);
        _decideFork();
      }
      if (recover && _alt == null && t - _lockTime >= lostAfterLock && t - _lastLostCheck >= lostEvery) {
        _lastLostCheck = t;
        _checkLost(k, t);
      }
      if (_pos >= _totalBeats) _pos = _totalBeats - 0.001;
    }

    if (_pos >= _totalBeats) _pos = _totalBeats - 0.001;
    final bool moving = _mode == FollowMode.tracking || _provisional;
    return FollowState(
      _mode,
      moving ? _pos / _beats : null,
      provisional: _mode != FollowMode.tracking && _provisional,
      (_mode == FollowMode.tracking ? _tempo : _nominalAt(_pos)) * 60,
      smooth,
      threshold,
      t,
    );
  }

  // ---- 들어온 곳 찾기
  void _search(int k, double t) {
    final List<int> region;
    if (_tapIndex != null) {
      region = <int>[_tapIndex!];
    } else if (_locks == 0) {
      region = <int>[_startIndex];
    } else {
      final int c = _lastStop ?? _startIndex;
      region = <int>[
        for (int i = math.max(0, c - 16); i <= math.min(path.length - 1, c + 2); i++) i
      ];
    }
    final double step = region.length > 1 ? 0.25 : 0.125;
    final List<double> bs = <double>[], ts = <double>[], m0 = <double>[];
    for (final int ms in region) {
      for (double f = 0.92; f <= 1.0801; f += 0.02) {
        final double tp = nominal * _rate[ms] * f;
        for (double d = 0; d < tp * (t - _onset + 0.5); d += step) {
          bs.add(ms * _beats + d);
          ts.add(tp);
          m0.add(ms * _beats.toDouble());
        }
      }
    }
    // 프레임 i(버퍼 기준) 이후 '소리 있음' 비율을 바로 구하려고 뒤에서부터 누적한다.
    final int first = math.max(_seg, _base) - _base, last = k - _base;
    final Int32List loudAfter = Int32List(last - first + 2);
    for (int i = last; i >= first; i--) {
      loudAfter[i - first] = loudAfter[i - first + 1] + (_loud[i] ? 1 : 0);
    }
    int best = -1;
    double bestScore = -1;
    for (int c = 0; c < bs.length; c++) {
      // 들어온 뒤로 소리가 끊김 없이 이어져야 한다.
      final double tau = t - (bs[c] - m0[c]) / ts[c];
      int lo = first, hi = last + 1; // tau 이후 첫 프레임
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (_times[mid] < tau) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      final int n = last - lo + 1;
      if (n <= 0 || loudAfter[lo - first] / n < 0.85) continue;
      final double s = _score(_seg, k, t, bs[c], ts[c], minBeat: m0[c]);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    if (best < 0) return;
    final int ms = m0[best] ~/ _beats;
    final double tau = t - (bs[best] - m0[best]) / ts[best];
    final bool stable = _prev != null && _prev!.$1 == ms && (_prev!.$2 - tau).abs() < 0.3;
    _prev = (ms, tau);
    if (!stable && t - _onset <= 8) return;
    _pos = bs[best];
    _tempo = ts[best];
    _mode = FollowMode.tracking;
    _provisional = false;
    _lastCorrection = t;
    _locks++;
    _tapIndex = null;
    _alt = null;
    _lastIndex = _pos ~/ _beats;
    _lockTime = t;
    _lastLostCheck = t;
    _challenger = null;
    _challengerHits = 0;
  }

  // ---- 1초마다 보정
  void _correct(int k, double t) {
    final (double s, double b, double tp) = _bestNear(k, t, _pos, _tempo);
    if (s >= 0) {
      _pos += 0.6 * (b - _pos);
      _tempo += 0.3 * (tp - _tempo);
    }
    final _Hyp? alt = _alt;
    if (alt == null) return;
    // 갈림길 뒤의 소리만으로 두 가설을 공평하게 채점한다. 갈림길 앞의 소리는
    // 건너뛴 가설의 연주 순서와 맞지 않는다.
    final (double sa, double ba, double ta) =
        _bestNear(k, t, alt.pos, alt.tempo, minBeat: alt.fork);
    if (sa >= 0) {
      alt.pos += 0.6 * (ba - alt.pos);
      alt.tempo += 0.3 * (ta - alt.tempo);
      alt.recent.add(sa);
    }
    final (double sm, _, _) = _bestNear(k, t, _pos, _tempo, minBeat: _mainFork);
    if (sm >= 0) _mainRecent.add(sm);
  }

  /// [pos] 근처(±[reach]박, 템포 ±4%)에서 가장 잘 맞는 위치와 점수.
  (double, double, double) _bestNear(int k, double t, double pos, double tempo,
      {double? minBeat, double reach = 2, double window = 6}) {
    final int from = math.max(_seg, k - (window / _dt).round());
    double bestScore = -1, bestValue = -double.infinity, bestB = pos, bestT = tempo;
    final double local = _nominalAt(pos);
    for (double db = -reach; db <= reach + 0.0001; db += 0.125) {
      for (double f = 0.96; f <= 1.0401; f += 0.01) {
        final double tp = (tempo * f).clamp(local * 0.85, local * 1.15);
        final double s = _score(from, k, t, pos + db, tp, minBeat: minBeat);
        if (s < 0) continue;
        // 화음이 오래 안 바뀌면 모든 후보가 똑같이 맞는다. 그때 맨 앞 후보
        // (2박 뒤·4% 느리게)가 뽑혀 점점 느려지고 뒤처졌다. 점수가 비슷하면
        // 지금 위치·템포에 가까운 쪽을 고른다.
        final double value = s - 0.004 * db.abs() - 0.1 * (f - 1).abs();
        if (value > bestValue) {
          bestValue = value;
          bestScore = s;
          bestB = pos + db;
          bestT = tp;
        }
      }
    }
    return (bestScore, bestB, bestT);
  }

  // ---- 갈림길: 악보 순서가 건너뛰는 곳(도돌이 등)을 지나면 '안 건너뛴' 쪽도 들고 간다
  void _maybeFork() {
    final int i = _pos ~/ _beats;
    if (i == _lastIndex) return;
    _lastIndex = i;
    if (!branches || _alt != null || i < 1 || i >= path.length) return;
    if (path[i] == path[i - 1] + 1) return;
    final int target = path[i - 1] + 1;
    int? j;
    for (int x = i; x < path.length && j == null; x++) {
      if (path[x] == target) j = x;
    }
    for (int x = 0; x < path.length && j == null; x++) {
      if (path[x] == target) j = x;
    }
    if (j == null) return;
    final double into = _pos - i * _beats;
    _alt = _Hyp(j * _beats + into, _tempo * _rateChange(_pos, j * _beats + into), j * _beats.toDouble());
    _mainFork = i * _beats.toDouble();
    _mainRecent.clear();
  }

  void _decideFork() {
    final _Hyp? alt = _alt;
    if (alt == null) return;
    if (_pos - _mainFork < 8 || alt.pos - alt.fork < 8) return;
    if (_mainRecent.length < 2 || alt.recent.length < 2) return;
    double mean(List<double> v) {
      final List<double> last = v.sublist(math.max(0, v.length - 3));
      return last.reduce((a, b) => a + b) / last.length;
    }

    final double gap = mean(alt.recent) - mean(_mainRecent);
    if (gap.abs() <= 0.03 && _pos - _mainFork < 16) return;
    if (gap > 0) {
      _pos = alt.pos;
      _tempo = alt.tempo;
    }
    _alt = null;
    _lastIndex = _pos ~/ _beats;
  }

  // ---- 길 잃음: 지금 위치보다 확실히 잘 맞는 곳이 근처에 계속 보이면 옮긴다
  void _checkLost(int k, double t) {
    final double window = lostWindow;
    final (double current, _, _) = _bestNear(k, t, _pos, _tempo, window: window);
    if (current < 0) return;
    final int ci = _pos ~/ _beats;
    // 잘못 간 곳은 맞는 곳보다 앞일 수도 뒤일 수도 있다(도돌이 목적지를
    // 잘못 읽으면 어느 쪽이든 된다). 앞뒤 24마디를 본다.
    final int lo = math.max(0, ci - 24) * _beats;
    final int hi = math.min(path.length, ci + 25) * _beats;
    final int from = math.max(_seg, k - (window / _dt).round());
    double best = -1, bestB = 0, bestT = _tempo;
    for (double b = lo.toDouble(); b < hi; b += 0.5) {
      if ((b - _pos).abs() < 3) continue;
      for (final double f in const <double>[0.97, 1.0, 1.03]) {
        final double tp = _tempo * _rateChange(_pos, b) * f;
        // 같은 화음 진행이 여러 번 나오는 곡에서 멀리 있는 똑같은 진행으로
        // 튀지 않도록, 멀수록 더 확실히 이겨야 한다(1마디당 0.002).
        final double s = _score(from, k, t, b, tp) - lostDistancePenalty * (b - _pos).abs() / _beats;
        if (s > best) {
          best = s;
          bestB = b;
          bestT = tp;
        }
      }
    }
    if (best - current < lostMargin) {
      _challenger = null;
      _challengerHits = 0;
      return;
    }
    final (double, double)? prev = _challenger;
    final bool same = prev != null && (bestB - (prev.$1 + _tempo * (t - prev.$2))).abs() < 2;
    _challengerHits = same ? _challengerHits + 1 : 1;
    _challenger = (bestB, t);
    if (_challengerHits >= lostHits) {
      _pos = bestB;
      _tempo = bestT;
      _lastIndex = _pos ~/ _beats;
      _challenger = null;
      _challengerHits = 0;
    }
  }

  /// 길 잃음 검사: 위치를 잡은 뒤 몇 초부터, 몇 초마다, 최근 몇 초 소리로
  /// 채점해서, 다른 위치가 지금 위치보다 [lostMargin]만큼 더 잘 맞는 일이
  /// 같은 곳에서 몇 번 연속 나와야 옮기는가.
  ///
  /// 노불달 녹음에서 밴드가 4~16마디 건너뛰거나 되돌아간 27개 장면으로 정했다.
  /// 원곡 기준은 다른 자리와 확실히 구별돼서 빠르게 검사해도 멀쩡한 연주에서
  /// 튀지 않는다(복구 중앙 14.6초 → 5.4초). 코드 기준은 같은 진행이 반복되는
  /// 곡에서 다른 자리도 똑같이 맞아 보여, 빠르게 하면 멀쩡한 연주에서 튄다.
  /// 그래서 더 오래 듣고 더 여러 번 확인한다(26.8초 → 12.4초).
  double lostAfterLock = 4;
  double lostEvery = 1;
  double lostWindow = 6;
  int lostHits = 4;
  double lostMargin = 0.04;

  /// 멀리 있는 후보가 마디당 더 이겨야 하는 점수. 같은 화음 진행이 반복되는
  /// 곡(먹이사슬 A7–D7)에서 똑같은 진행이 있는 먼 곳으로 튀지 않게 한다.
  double lostDistancePenalty = 0.002;

  /// 크로마 프레임이 실제 소리보다 늦게 나오는 정도(초).
  double featureDelay = 0;

  /// 이 가설(지금 [bEnd]박, 템포 [tempo])대로라면 최근 소리가 코드 진행과
  /// 얼마나 맞는가. 채점할 소리가 2초도 안 되면 -1.
  double _score(int from, int to, double tEnd, double bEnd, double tempo, {double? minBeat}) {
    double acc = 0;
    int n = 0;
    for (int f = math.max(from, _base); f <= to; f++) {
      final int i = f - _base;
      // 크로마 프레임은 창(0.19초)과 평활(지수이동평균) 때문에 조금 전의 소리를
      // 담고 있다. 그만큼 앞으로 당겨 맞춰야 위치가 늦지 않는다.
      final double beat = bEnd - tempo * (tEnd - (_times[i] - featureDelay));
      if (minBeat != null && beat < minBeat) continue;
      final int bi = (beat * _res).floor();
      if (bi < 0 || bi >= _rows.length) continue;
      final int id = _rows[bi];
      if (id < 0) continue;
      acc += _sims[i][id];
      n++;
    }
    return n * _dt < 2.0 ? -1 : acc / n;
  }

  double _quietShare(int k, double seconds) {
    final int n = (seconds / _dt).round();
    if (k - n < _base) return 0;
    int q = 0;
    for (int f = k - n; f <= k; f++) {
      if (!_loud[f - _base]) q++;
    }
    return q / (n + 1);
  }

  void _trim() {
    final int keep = (12.0 / _dt).round();
    final int extra = _times.length - keep;
    if (extra <= 0) return;
    _times.removeRange(0, extra);
    _sims.removeRange(0, extra);
    _loud.removeRange(0, extra);
    _base += extra;
    if (_dbs.length > keep * 2) _dbs.removeRange(0, _dbs.length - keep);
  }
}

class _Hyp {
  double pos;
  double tempo;

  /// 이 가설이 갈라져 나온 박 위치. 이보다 앞의 소리로는 채점하지 않는다.
  final double fork;
  final List<double> recent = <double>[];

  _Hyp(this.pos, this.tempo, this.fork);
}
