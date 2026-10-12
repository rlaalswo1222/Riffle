import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import '../services/chord_chart.dart';
import '../services/chroma_stream.dart';
import '../services/follow_settings.dart';
import '../services/reference_track.dart';
import '../services/score_follower.dart';
import '../services/score_pdf_document.dart';
import '../ui/toss.dart';
import '../widgets/score_page_view.dart';

/// 준비 화면에서 넘겨받는 것들.
class PreparedScore {
  final ScorePdfDocument document;
  final String title;
  final MeasureMap map;
  final ChordChart chart;
  final double bpm;
  final ReferenceTrack? reference;
  final int startIndex;

  const PreparedScore({
    required this.document,
    required this.title,
    required this.map,
    required this.chart,
    required this.bpm,
    required this.reference,
    required this.startIndex,
  });
}

/// 연주 화면: 악보만 크게 띄우고, 지금 치는 마디를 짚으며 페이지를 넘긴다.
class PerformanceScreen extends StatefulWidget {
  final PreparedScore score;
  final FollowSettings settings;

  const PerformanceScreen({super.key, required this.score, required this.settings});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final Map<int, (Uint8List, double)> _pages = <int, (Uint8List, double)>{};

  late final List<int> _path =
      widget.score.map.playbackBars.map((PlaybackBar b) => b.physicalMeasure).toList();
  late int _startIndex = widget.score.startIndex;
  late FollowSettings _settings = widget.settings;

  int _page = 0;
  bool _rendering = false;

  StreamSubscription<Uint8List>? _subscription;
  ChromaStream? _chroma;
  ScoreFollower? _follower;
  FollowState? _state;
  double? _shown;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

  bool _barVisible = true;
  Timer? _hideTimer;

  bool get _recording => _subscription != null;
  PreparedScore get _s => widget.score;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    final MeasureBand? first = _s.map.bandOfPlayback(_startIndex.toDouble());
    _showPage(first?.page ?? 0);
    _prerender();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _subscription?.cancel();
    _recorder.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------------------------------------------------------------- 페이지
  Future<(Uint8List, double)?> _render(int page) async {
    final (Uint8List, double)? cached = _pages[page];
    if (cached != null) return cached;
    final double aspect = await _s.document.pageAspectRatio(page);
    final Uint8List? image = await _s.document.renderPage(page);
    if (image == null) return null;
    return _pages[page] = (image, aspect);
  }

  /// 모든 페이지를 미리 그려 둔다. 연주 중에 그리면 넘김이 늦어진다.
  Future<void> _prerender() async {
    for (int p = 0; p < _s.document.pagesCount; p++) {
      if (!mounted) return;
      final (Uint8List, double)? r = await _render(p);
      if (r != null && mounted) await precacheImage(MemoryImage(r.$1), context);
    }
  }

  Future<void> _showPage(int page) async {
    if (page < 0 || page >= _s.document.pagesCount) return;
    _rendering = true;
    final (Uint8List, double)? r = await _render(page);
    _rendering = false;
    if (!mounted || r == null) return;
    setState(() => _page = page);
  }

  // ---------------------------------------------------------------- 녹음
  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) Toss.toast(context, '마이크를 쓸 수 있게 허용해 주세요');
      return;
    }
    _chroma = ChromaStream();
    _follower = ScoreFollower(
      chart: _s.chart,
      path: _path,
      bpm: _s.bpm,
      split: _settings.split,
      startIndex: _startIndex,
      reference: _settings.useReference ? _s.reference : null,
    );
    try {
      final Stream<Uint8List> stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: ChromaStream.sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.mic),
      ));
      setState(() {
        _subscription = stream.listen(_onPcm);
        _state = null;
        _shown = null;
      });
    } catch (error) {
      if (mounted) Toss.toast(context, '녹음을 시작하지 못했어요');
    }
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    await _recorder.stop();
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _subscription = null;
      _barVisible = true;
      if (_shown != null) _startIndex = _shown!.floor().clamp(0, _path.length - 1);
      _state = null;
    });
  }

  void _onPcm(Uint8List bytes) {
    final ChromaStream? chroma = _chroma;
    final ScoreFollower? follower = _follower;
    if (chroma == null || follower == null) return;
    FollowState? latest;
    for (final AudioFrame f in chroma.addPcm16(bytes)) {
      latest = follower.add(f);
    }
    if (latest == null || !mounted) return;

    // 마이크·스피커 지연만큼 앞당겨 보여 준다.
    final double? shown = latest.timeline == null
        ? null
        : (latest.timeline! +
                _settings.leadSeconds * latest.bpm / 60 / ChordChart.beatsPerMeasure)
            .clamp(0.0, _path.length - 0.001);
    final bool startedTracking =
        latest.mode == FollowMode.tracking && _state?.mode != FollowMode.tracking;
    final bool changed = _shown?.floor() != shown?.floor() ||
        _state?.mode != latest.mode ||
        _state?.provisional != latest.provisional;
    final DateTime now = DateTime.now();
    if (!changed && now.difference(_lastPaint).inMilliseconds < 100) {
      _state = latest;
      _shown = shown;
      return;
    }
    _lastPaint = now;
    setState(() {
      _state = latest;
      _shown = shown;
    });
    if (startedTracking) _scheduleHide();

    // 몇 박 뒤의 위치가 다른 페이지면 미리 넘긴다.
    if (shown != null && !_rendering) {
      final MeasureBand? ahead = _s.map.bandOfPlayback(
          (shown + _settings.turnBeats / ChordChart.beatsPerMeasure).clamp(0.0, _path.length - 0.001));
      final int target = ahead?.page ?? _page;
      if (target != _page) _showPage(target);
    }
  }

  // ---------------------------------------------------------------- 조작
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _recording && _state?.mode == FollowMode.tracking) {
        setState(() => _barVisible = false);
      }
    });
  }

  void _showBar() {
    setState(() => _barVisible = true);
    if (_recording && _state?.mode == FollowMode.tracking) _scheduleHide();
  }

  void _onTapScore(double x, double y) {
    final PlaybackPosition? p = _s.map.playbackPositionAt(_page, x, y, currentTimeline: _shown);
    if (p == null) {
      _showBar();
      return;
    }
    final int index = p.timeline.floor();
    if (_recording) {
      // "지금 여기야": 막대가 숨어 있어도 탭 한 번에 바로 옮긴다. 위치가 틀렸을
      // 때 연주하면서 고칠 수 있는 유일한 수단이라 한 번에 먹혀야 한다.
      _follower?.tap(index);
      setState(() {
        _shown = index.toDouble();
        _barVisible = true;
      });
      Toss.toast(context, '${_path[index]}마디부터 다시 따라갈게요');
      _scheduleHide();
    } else {
      setState(() => _startIndex = index);
    }
  }

  void _swipe(DragEndDetails d) {
    final double v = d.primaryVelocity ?? 0;
    if (v.abs() < 250) return;
    _showPage(_page + (v < 0 ? 1 : -1));
  }

  Future<void> _openSettings() async {
    final FollowSettings s = FollowSettings(
      split: _settings.split,
      leadSeconds: _settings.leadSeconds,
      turnBeats: _settings.turnBeats,
      useReference: _settings.useReference,
    );
    final bool? ok = await showTossSheet<bool>(
      context: context,
      title: '고급 설정',
      description: '대부분 그대로 두면 돼요. 바꾼 값은 다음 녹음부터 적용돼요.',
      child: _SettingsSheet(settings: s, hasReference: _s.reference != null),
    );
    if (ok != true || !mounted) return;
    await s.save();
    setState(() => _settings = s);
  }

  // ---------------------------------------------------------------- 화면
  @override
  Widget build(BuildContext context) {
    final FollowState? st = _state;
    final bool tracking = st?.mode == FollowMode.tracking;
    final bool provisional = st != null && st.provisional && _shown != null;

    final FollowLook look;
    final MeasureBand? band;
    if (_shown != null && (tracking || provisional)) {
      look = tracking ? FollowLook.tracking : FollowLook.provisional;
      band = _s.map.bandOfPlayback(_shown!);
    } else {
      look = FollowLook.start;
      band = _s.map.bandOfPlayback(_startIndex.toDouble());
    }
    final MeasureBand? next = tracking ? _nextLine(band) : null;
    final (Uint8List, double)? page = _pages[_page];

    return Scaffold(
      backgroundColor: Toss.white,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onHorizontalDragEnd: _swipe,
              child: SafeArea(
                child: page == null
                    ? const Center(child: CircularProgressIndicator(color: Toss.blue))
                    : ScorePageView(
                        image: page.$1,
                        aspectRatio: page.$2,
                        map: _s.map,
                        page: _page,
                        highlight: band,
                        nextLine: next,
                        look: look,
                        zoomable: false,
                        onTapPosition: _onTapScore,
                      ),
              ),
            ),
          ),
          Positioned(top: 16, left: 16, child: SafeArea(child: _statusPill())),
          Positioned(
            top: 16,
            right: 16,
            child: SafeArea(
              child: AnimatedOpacity(
                opacity: _barVisible ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: _roundButton(Icons.close_rounded, () => Navigator.pop(context)),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: AnimatedSlide(
                offset: _barVisible ? Offset.zero : const Offset(0, 0.4),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: _barVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(ignoring: !_barVisible, child: _bar()),
                ),
              ),
            ),
          ),
          if (!_barVisible)
            Positioned(
              right: 20,
              bottom: 18,
              child: SafeArea(
                child: Text('화면을 누르면 막대가 다시 나와요', style: Toss.label.copyWith(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  /// 연주 순서에서 지금 줄 다음에 오는 줄의 첫 마디(도돌이로 돌아가는 곳 포함).
  /// 같은 쪽이면 줄의 절반을 넘었을 때만, 다른 쪽이면 늘 돌려준다. 페이지를
  /// 미리 넘기면 지금 마디는 안 보이고 이것만 보이기 때문이다.
  MeasureBand? _nextLine(MeasureBand? band) {
    final double? shown = _shown;
    if (band == null || shown == null) return null;
    MeasureBand? next;
    for (int k = 1; k <= 8 && next == null; k++) {
      final MeasureBand? b = _s.map.bandOfPlayback((shown.floor() + k).toDouble());
      if (b == null) return null;
      if (b.top != band.top || b.page != band.page) next = b;
    }
    if (next == null || next.page != band.page) return next;
    final int m = _path[shown.floor()];
    final double span = band.endMeasure - band.startMeasure;
    if (span <= 0 || (m - band.startMeasure + 1) / span < 0.5) return null;
    return next;
  }

  Widget _statusPill() {
    final FollowState? st = _state;
    Color dot = Toss.g400;
    String text = '대기 중';
    if (_recording) {
      if (st == null || st.mode == FollowMode.waiting) {
        text = '연주를 기다리는 중';
      } else if (_shown == null) {
        dot = Toss.blue;
        text = '소리를 찾는 중';
      } else {
        dot = st.mode == FollowMode.tracking ? Toss.green : Toss.blue;
        text = '${_path[_shown!.floor()]}마디';
      }
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 13, 7),
      decoration: BoxDecoration(
        color: Toss.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x1A191F28), blurRadius: 12, offset: Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 9, height: 9, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(text, style: Toss.body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap) => Material(
        color: Toss.white,
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: const Color(0x33191F28),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 44, height: 44, child: Icon(icon, color: Toss.g700)),
        ),
      );

  Widget _bar() {
    final FollowState? st = _state;
    String big, small;
    if (!_recording) {
      big = '${_path[_startIndex]}마디부터 시작할게요';
      small = '악보를 누르면 시작 위치를 바꿀 수 있어요';
    } else if (st == null || st.mode == FollowMode.waiting) {
      big = '연주를 기다리고 있어요';
      small = st == null ? '소리가 나면 바로 따라가요' : '입력 ${st.db.round()}dB · ${st.threshold.round()}dB를 넘으면 시작해요';
    } else if (_shown == null) {
      big = '연주 소리를 찾고 있어요';
      small = '몇 초 안에 따라가요 · 틀리면 지금 마디를 눌러 주세요';
    } else {
      final int m = _path[_shown!.floor()];
      final String chord = _s.chart.chordNameAt(m) ?? '';
      big = '$m마디${chord.isEmpty ? '' : ' · $chord'}';
      small = st.provisional
          ? '소리로 위치를 확인하고 있어요'
          : '틀리면 지금 치는 마디를 눌러 주세요 · ♩${st.bpm.round()} · '
              '${_settings.useReference && _s.reference != null ? '원곡' : '코드'} 기준';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      decoration: BoxDecoration(
        color: Toss.g900.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(big,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: Toss.font,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Toss.white,
                        letterSpacing: -0.4)),
                const SizedBox(height: 2),
                Text(small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Toss.caption.copyWith(color: Toss.g400, fontSize: 13)),
              ],
            ),
          ),
          IconButton(
            onPressed: _recording ? null : _openSettings,
            icon: Icon(Icons.tune_rounded, color: _recording ? Toss.g700 : Toss.g400),
            tooltip: '고급 설정',
          ),
          const SizedBox(width: 4),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _recording ? _stop : _start,
              icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded, size: 20),
              label: Text(_recording ? '멈추기' : '녹음 시작'),
              style: FilledButton.styleFrom(
                backgroundColor: _recording ? Toss.white : Toss.blue,
                foregroundColor: _recording ? Toss.g900 : Toss.white,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(fontFamily: Toss.font, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 고급 설정 바텀시트.
class _SettingsSheet extends StatefulWidget {
  final FollowSettings settings;
  final bool hasReference;

  const _SettingsSheet({required this.settings, required this.hasReference});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  FollowSettings get s => widget.settings;

  Widget _slider(String title, String value, String help, double v, double min, double max, int div,
          ValueChanged<double> onChanged) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(title, style: Toss.body)),
              Text(value, style: Toss.body.copyWith(color: Toss.blue)),
            ],
          ),
          Slider(value: v, min: min, max: max, divisions: div, activeColor: Toss.blue, onChanged: onChanged),
          Text(help, style: Toss.caption),
          const SizedBox(height: 14),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (widget.hasReference)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('원곡 기준으로 따라가기', style: Toss.body),
              subtitle: const Text('끄면 악보의 코드만 보고 따라가요', style: Toss.caption),
              value: s.useReference,
              activeTrackColor: Toss.blue,
              onChanged: (bool v) => setState(() => s.useReference = v),
            ),
          _slider('연주 감지', '${(s.split * 100).round()}%', '연주 중인데 자꾸 기다리면 낮추고, 조용한데 소리를 찾으면 올려요',
              s.split, 0.2, 0.5, 6, (double v) => setState(() => s.split = v)),
          _slider('위치 앞당기기', '${s.leadSeconds.toStringAsFixed(1)}초', '표시가 연주보다 늦으면 올려요',
              s.leadSeconds, 0, 1, 10, (double v) => setState(() => s.leadSeconds = v)),
          _slider('페이지 미리 넘기기', '${s.turnBeats.round()}박 전', '다음 쪽 첫 줄을 미리 보고 싶으면 올려요',
              s.turnBeats, 0, 8, 8, (double v) => setState(() => s.turnBeats = v)),
          TossButton('저장하기', onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
  }
}
