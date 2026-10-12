import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/measure_map.dart';
import '../services/chord_chart.dart';
import '../services/follow_settings.dart';
import '../services/local_score_analyzer.dart';
import '../services/original_audio.dart';
import '../services/original_reference.dart';
import '../services/reference_track.dart';
import '../services/score_analysis_cache.dart';
import '../services/score_library.dart';
import '../services/score_pdf_document.dart';
import '../services/score_pdf_renderer.dart';
import '../ui/toss.dart';
import '../widgets/original_picker.dart';
import 'performance_screen.dart';

/// 연주 전 준비: 악보에서 읽은 내용을 보여 주고, 틀린 건 여기서 바로 고친다.
class PrepScreen extends StatefulWidget {
  final LibraryEntry entry;

  const PrepScreen({super.key, required this.entry});

  @override
  State<PrepScreen> createState() => _PrepScreenState();
}

class _PrepScreenState extends State<PrepScreen> {
  ScorePdfDocument? _document;
  MeasureMap? _map;
  ChordChart? _chart;
  String? _error;
  double _bpm = 120;

  ReferenceTrack? _reference;
  String? _referenceName;
  String? _originalWork; // 원곡을 찾거나 받는 중일 때 안내 문구
  double? _originalProgress;

  LibraryEntry get _e => widget.entry;
  List<int> get _path =>
      _map!.playbackBars.map((PlaybackBar b) => b.physicalMeasure).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _document?.close();
    super.dispose();
  }

  Future<void> _load() async {
    ScorePdfDocument? document;
    String? analysisFailure;
    try {
      final Uint8List bytes = await ScoreLibrary.bytesOf(_e.key);
      final ScorePdfDocument opened = await openScorePdf(bytes);
      document = opened;
      final ScoreAnalysisCache cache = await ScoreLibrary.analysisCache();
      final CachedScoreAnalysis prepared = await cache.getOrAnalyze(
        _e.key,
        pagesCount: opened.pagesCount,
        analyze: () async {
          final LocalScoreAnalysis analysis =
              await LocalScoreAnalyzer().analyze(opened, fileName: _e.fileName);
          if (!analysis.isUsable) {
            analysisFailure = analysis.failureReason ?? '이 악보의 마디 구조를 읽지 못했어요.';
            throw StateError(analysisFailure!);
          }
          final List<ScorePdfPageText> pages = <ScorePdfPageText>[
            for (int p = 0; p < opened.pagesCount; p++)
              await opened.extractPageText(p),
          ];
          return CachedScoreAnalysis(
            title: analysis.title,
            artist: analysis.artist,
            map: analysis.map,
            chart: ChordChart.fromPdf(pages, analysis.map),
          );
        },
      );
      if (!mounted) return;
      final ChordChart chart = prepared.chart;
      _document = document;
      _map = prepared.map;
      _chart = chart;
      _bpm = _e.bpm ?? chart.printedBpm ?? 120;
      final (ReferenceTrack, String?)? saved =
          await OriginalReference.load(_e.key, _path, tempoChanges: chart.tempoChanges);
      _reference = saved?.$1;
      _referenceName = saved?.$2;

      _e
        ..title = prepared.title.isNotEmpty ? prepared.title : _e.title
        ..artist = prepared.artist
        ..measures = chart.measureCount
        ..chordMeasures = chart.measuresWithSymbols
        ..repeats = prepared.map.repeats.length
        ..bpm = _bpm
        ..hasOriginal = _reference != null;
      await ScoreLibrary.save(_e);
      if (!mounted) return;
      setState(() {});
      if (_reference == null) {
        // 도돌이 인식이 바뀌어 연주 순서가 달라졌으면 받아 둔 원곡으로 다시 맞춘다.
        final (String, String, bool)? previous = await OriginalReference.previousAudio(_e.key);
        if (previous != null && mounted) {
          unawaited(_build(previous.$1, previous.$2, downloaded: previous.$3));
          return;
        }
        // 처음 여는 악보면 원곡을 바로 찾아 준다.
        if (!_e.originalSkipped && mounted) unawaited(_findOriginal());
      }
    } catch (error) {
      if (mounted) setState(() => _error = analysisFailure ?? 'PDF를 열지 못했어요: $error');
    } finally {
      if (document != null && !identical(document, _document)) {
        await document.close();
      }
    }
  }

  // ---------------------------------------------------------------- 원곡
  Future<void> _findOriginal() async {
    if (_map == null || _originalWork != null) return;
    setState(() {
      _originalWork = '원곡을 찾고 있어요';
      _originalProgress = null;
    });
    final OriginalSearchSession search = OriginalAudio.startSearch(
      _e.title,
      _e.artist,
      expected: Duration(
          seconds: (_path.length * ChordChart.beatsPerMeasure * 60 / _bpm)
              .round()),
    );
    Object? choice;
    try {
      await search.loadMore();
      if (!mounted) return;
      setState(() => _originalWork = null);
      choice = await showTossSheet<Object>(
        context: context,
        title: '원곡을 골라 주세요',
        description: '원곡과 맞춰 두면 위치를 더 정확하게 따라가요',
        child: OriginalPicker(search: search),
      );
    } finally {
      search.dispose();
    }
    if (!mounted) return;
    if (choice is OriginalCandidate) {
      await _attachYoutube(choice);
    } else if (choice == OriginalPicker.fromFile) {
      await _attachFile();
    } else if (_reference == null) {
      _e.originalSkipped = true;
      await ScoreLibrary.save(_e);
    }
  }

  Future<void> _attachYoutube(OriginalCandidate c) async {
    setState(() {
      _originalWork = '원곡을 받고 있어요';
      _originalProgress = null;
    });
    try {
      final String file = await OriginalAudio.download(
        c.id,
        await OriginalReference.folder(),
        onProgress: (double p) {
          if (mounted) {
            setState(() {
              _originalWork = '원곡을 받고 있어요 ${p.round()}%';
              _originalProgress = (p / 100).clamp(0.0, 1.0);
            });
          }
        },
      );
      await _build(file, c.title, downloaded: true);
    } catch (error) {
      if (mounted) {
        setState(() => _originalWork = null);
        Toss.toast(context, '원곡을 받지 못했어요. 휴대폰 파일로 골라 주세요.');
      }
    }
  }

  Future<void> _attachFile() async {
    final FilePickerResult? picked =
        await FilePicker.platform.pickFiles(type: FileType.audio);
    final String? file = picked?.files.single.path;
    if (file == null || !mounted) return;
    await _build(file, picked!.files.single.name);
  }

  Future<void> _build(String file, String label, {bool downloaded = false}) async {
    final ChordChart? chart = _chart;
    if (chart == null) return;
    setState(() {
      _originalWork = '원곡을 악보에 맞추고 있어요';
      _originalProgress = null;
    });
    try {
      final ReferenceTrack ref = await OriginalReference.build(
        key: _e.key,
        audioFile: file,
        label: label,
        chart: chart,
        path: _path,
        bpm: _bpm,
        downloaded: downloaded,
      );
      _e
        ..hasOriginal = true
        ..originalSkipped = false;
      await ScoreLibrary.save(_e);
      if (!mounted) return;
      setState(() {
        _reference = ref;
        _referenceName = label;
        _originalWork = null;
      });
      if (ref.fit < 0.7) {
        Toss.toast(context, '원곡과 악보가 잘 안 맞아요. 다른 음원을 골라 보세요.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _originalWork = null);
        Toss.toast(context, '원곡을 맞추지 못했어요. 다른 음원을 골라 보세요.');
      }
    }
  }

  // ---------------------------------------------------------------- 고치기
  Future<void> _editTempo() async {
    final TextEditingController c =
        TextEditingController(text: _bpm.round().toString());
    final double? value = await showTossSheet<double>(
      context: context,
      title: '템포를 알려 주세요',
      description: '악보에 적힌 ♩ 숫자예요. 실제로 조금 빠르거나 느려도 따라가요.',
      child: _NumberInput(
          controller: c, suffix: 'BPM', min: 30, max: 300, cta: '이 템포로 할게요'),
    );
    if (value == null || !mounted) return;
    setState(() => _bpm = value);
    _e.bpm = value;
    await ScoreLibrary.save(_e);
  }

  Future<void> _start() async {
    final ScorePdfDocument? document = _document;
    if (document == null || _map == null || _chart == null) return;
    final FollowSettings settings = await FollowSettings.load();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PerformanceScreen(
        score: PreparedScore(
          document: document,
          title: _e.title,
          map: _map!,
          chart: _chart!,
          bpm: _bpm,
          reference: _reference,
          startIndex: 0,
        ),
        settings: settings,
      ),
    ));
  }

  // ---------------------------------------------------------------- 화면
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Toss.g100,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: Toss.g800),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _error != null
                ? _errorView()
                : _map == null
                    ? _loading()
                    : _ready(),
          ),
        ),
      ),
    );
  }

  Widget _loading() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('악보를 불러오고 있어요', style: Toss.title),
            const SizedBox(height: 4),
            Text(_e.title, style: Toss.caption.copyWith(fontSize: 14.5)),
            const SizedBox(height: 28),
            const LinearProgressIndicator(
                minHeight: 6, color: Toss.blue, backgroundColor: Toss.g200),
            const SizedBox(height: 10),
            const Text('처음 여는 악보는 마디선, 코드, 도돌이표를 찾아요', style: Toss.caption),
          ],
        ),
      );

  Widget _errorView() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('이 악보는 읽지 못했어요', style: Toss.title),
            const SizedBox(height: 6),
            Text(_error!, style: Toss.caption.copyWith(fontSize: 14.5)),
            const Spacer(),
            TossButton('악보함으로 돌아가기', onPressed: () => Navigator.pop(context)),
          ],
        ),
      );

  Widget _ready() {
    final ChordChart chart = _chart!;
    final MeasureMap map = _map!;
    final bool fewChords = chart.measuresWithSymbols < 8;
    final bool busy = _originalWork != null;
    final String originalText = busy
        ? _originalWork!
        : _reference == null
            ? '없어요 · 있으면 더 정확하게 따라가요'
            : '${_referenceName ?? '원곡'} · ${_reference!.keyShift == 0 ? '같은 키' : '키 차이 ${_reference!.keyShift > 0 ? '+' : ''}${_reference!.keyShift}'}';
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Text(
                  fewChords ? '이 악보는 따라가기\n어려울 수 있어요' : '연주할 준비가\n거의 끝났어요',
                  style: Toss.title.copyWith(fontSize: 26),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                child: Text(
                  '${_e.title}${_e.artist.isEmpty ? '' : ' · ${_e.artist}'}',
                  style: Toss.caption.copyWith(fontSize: 14.5),
                ),
              ),
              TossCard(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Column(
                  children: <Widget>[
                    TossRow(
                      leading: const TossStatus(),
                      title: '마디',
                      subtitle: '${chart.measureCount}마디, '
                          '${map.hasRepeats ? '도돌이 ${map.repeats.length}개 · 연주 순서 ${map.playbackLength}마디' : '도돌이는 없어요'}',
                    ),
                    TossRow(
                      leading: TossStatus(ok: !fewChords),
                      title: '코드',
                      subtitle: fewChords
                          ? '코드를 거의 못 읽었어요 · 원곡이 있으면 도움이 돼요'
                          : '${chart.measureCount}마디 중 ${chart.measuresWithSymbols}마디에서 읽었어요',
                    ),
                    TossRow(
                      leading: const TossStatus(),
                      title: '템포',
                      subtitle:
                          '♩${_bpm.round()}${chart.printedBpm == null ? ' · 악보에서 못 찾아서 정해 두었어요' : ''}',
                      trailing: const Text('수정', style: Toss.action),
                      onTap: _editTempo,
                    ),
                    TossRow(
                      leading: TossStatus(ok: _reference != null, busy: busy),
                      title: '원곡',
                      subtitle: originalText,
                      trailing: busy
                          ? null
                          : Text(_reference == null ? '찾기' : '바꾸기',
                              style: Toss.action),
                      onTap: busy ? null : _findOriginal,
                    ),
                    if (busy)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: _originalProgress,
                            minHeight: 6,
                            color: Toss.blue,
                            backgroundColor: Toss.g100,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: TossButton('연주 시작하기', onPressed: busy ? null : _start),
        ),
      ],
    );
  }
}

/// 숫자 하나를 크게 입력받는 바텀시트 내용.
class _NumberInput extends StatefulWidget {
  final TextEditingController controller;
  final String suffix;
  final double min;
  final double max;
  final String cta;

  const _NumberInput({
    required this.controller,
    required this.suffix,
    required this.min,
    required this.max,
    required this.cta,
  });

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  double? get _value {
    final double? v = double.tryParse(widget.controller.text);
    return v != null && v >= widget.min && v <= widget.max ? v : null;
  }

  @override
  Widget build(BuildContext context) {
    final double? v = _value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: widget.controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly
          ],
          onChanged: (_) => setState(() {}),
          style: Toss.title.copyWith(fontSize: 30),
          decoration: InputDecoration(
            suffixText: widget.suffix,
            suffixStyle: Toss.subtitle.copyWith(color: Toss.g500),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Toss.g200, width: 2)),
            focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Toss.blue, width: 2)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          v == null
              ? '${widget.min.round()}~${widget.max.round()} 사이로 입력해 주세요'
              : ' ',
          style: Toss.caption.copyWith(color: Toss.red),
        ),
        const SizedBox(height: 14),
        TossButton(widget.cta,
            onPressed: v == null ? null : () => Navigator.pop(context, v)),
      ],
    );
  }
}

