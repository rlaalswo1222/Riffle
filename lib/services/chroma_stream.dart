import 'dart:math' as math;
import 'dart:typed_data';

/// 소리 한 조각(약 0.05초)의 특징.
class AudioFrame {
  /// 녹음 시작부터의 시각(초). 이 프레임을 계산할 수 있게 된 시점이다.
  final double time;

  /// 12음 크로마. C, C#, … B 순서이고 L2 정규화돼 있다.
  final Float64List chroma;

  /// 창 안의 음량(dBFS).
  final double db;

  const AudioFrame(this.time, this.chroma, this.db);
}

/// 마이크 PCM을 받아 12음 크로마 프레임으로 바꾼다.
///
/// 파이썬 시뮬레이션(librosa chroma_stft, n_fft 4096, hop 1024)과 같은 계산을
/// 과거 소리만 써서 한다. 창의 '끝' 시각을 프레임 시각으로 삼으므로
/// 미래를 들여다보지 않는다.
class ChromaStream {
  static const int sampleRate = 22050;
  static const int fftSize = 4096;
  static const int hop = 1024;
  static const double frameSeconds = hop / sampleRate;

  final Float64List _ring = Float64List(fftSize);
  int _filled = 0;
  int _sinceHop = 0;
  int _consumed = 0;
  int? _pendingByte;

  final Float64List _window = Float64List(fftSize);
  final Int32List _pitchClass = Int32List(fftSize ~/ 2 + 1);
  final Float64List _ema = Float64List(12);
  final Float64List _re = Float64List(fftSize);
  final Float64List _im = Float64List(fftSize);
  late final Float64List _cos;
  late final Float64List _sin;
  late final Int32List _bitrev;

  ChromaStream() {
    for (int i = 0; i < fftSize; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / fftSize);
    }
    for (int k = 0; k <= fftSize ~/ 2; k++) {
      final double f = k * sampleRate / fftSize;
      if (f < 55 || f > 4200) {
        _pitchClass[k] = -1;
        continue;
      }
      final double midi = 69 + 12 * math.log(f / 440) / math.ln2;
      _pitchClass[k] = midi.round() % 12;
    }
    _cos = Float64List(fftSize ~/ 2);
    _sin = Float64List(fftSize ~/ 2);
    for (int i = 0; i < fftSize ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / fftSize);
      _sin[i] = math.sin(-2 * math.pi * i / fftSize);
    }
    final int bits = (math.log(fftSize) / math.ln2).round();
    _bitrev = Int32List(fftSize);
    for (int i = 0; i < fftSize; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        r |= ((i >> b) & 1) << (bits - 1 - b);
      }
      _bitrev[i] = r;
    }
  }

  /// 16비트 리틀엔디언 모노 PCM 바이트. 조각 경계가 홀수여도 된다.
  List<AudioFrame> addPcm16(Uint8List bytes) {
    final List<AudioFrame> out = <AudioFrame>[];
    int i = 0;
    if (_pendingByte != null && bytes.isNotEmpty) {
      _push(_toSample(_pendingByte!, bytes[0]), out);
      _pendingByte = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _push(_toSample(bytes[i], bytes[i + 1]), out);
    }
    if (i < bytes.length) _pendingByte = bytes[i];
    return out;
  }

  /// -1~1 범위 실수 샘플. 테스트와 파일 재생용.
  List<AudioFrame> addSamples(Float64List samples) {
    final List<AudioFrame> out = <AudioFrame>[];
    for (final double s in samples) {
      _push(s, out);
    }
    return out;
  }

  static double _toSample(int lo, int hi) {
    int v = lo | (hi << 8);
    if (v >= 0x8000) v -= 0x10000;
    return v / 32768.0;
  }

  void _push(double sample, List<AudioFrame> out) {
    _ring[_filled % fftSize] = sample;
    _filled++;
    _consumed++;
    _sinceHop++;
    if (_filled >= fftSize && (_filled == fftSize || _sinceHop >= hop)) {
      _sinceHop = 0;
      out.add(_frame(_consumed / sampleRate));
    }
  }

  AudioFrame _frame(double time) {
    final int start = _filled % fftSize; // 가장 오래된 샘플 위치
    double energy = 0;
    for (int n = 0; n < fftSize; n++) {
      final double s = _ring[(start + n) % fftSize];
      energy += s * s;
      final int j = _bitrev[n];
      _re[j] = s * _window[n];
      _im[j] = 0;
    }
    _fft();

    final Float64List c = Float64List(12);
    for (int k = 1; k <= fftSize ~/ 2; k++) {
      final int p = _pitchClass[k];
      if (p < 0) continue;
      c[p] += _re[k] * _re[k] + _im[k] * _im[k];
    }
    double peak = 0;
    for (final double x in c) {
      if (x > peak) peak = x;
    }
    for (int p = 0; p < 12; p++) {
      final double v = peak > 0 ? c[p] / peak : 0;
      _ema[p] = 0.75 * _ema[p] + 0.25 * math.log(1 + 100 * v);
    }
    double norm = 0;
    for (final double x in _ema) {
      norm += x * x;
    }
    norm = math.sqrt(norm) + 1e-9;
    final Float64List chroma = Float64List(12);
    for (int p = 0; p < 12; p++) {
      chroma[p] = _ema[p] / norm;
    }
    final double rms = math.sqrt(energy / fftSize);
    return AudioFrame(time, chroma, 20 * math.log(rms + 1e-9) / math.ln10);
  }

  void _fft() {
    for (int size = 2; size <= fftSize; size <<= 1) {
      final int half = size >> 1;
      final int step = fftSize ~/ size;
      for (int i = 0; i < fftSize; i += size) {
        for (int j = 0; j < half; j++) {
          final double wr = _cos[j * step], wi = _sin[j * step];
          final int a = i + j, b = a + half;
          final double tr = _re[b] * wr - _im[b] * wi;
          final double ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
  }
}
