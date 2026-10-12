import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';
import '../services/local_score_analyzer.dart';
import '../services/score_pdf_document.dart';
import '../services/score_pdf_renderer.dart';
import '../widgets/anchor_range_dialog.dart';
import '../widgets/score_page_view.dart';

/// 서버 없이 한 기기에서 여러 악보의 위치 동기화를 확인하는 화면.
class LocalSyncScreen extends StatefulWidget {
  const LocalSyncScreen({super.key});

  @override
  State<LocalSyncScreen> createState() => _LocalSyncScreenState();
}

class _LocalSyncScreenState extends State<LocalSyncScreen> {
  static const int _maxScores = 6;

  final LocalScoreAnalyzer _analyzer = LocalScoreAnalyzer();
  final List<_LocalScore> _scores = <_LocalScore>[];
  bool _uploading = false;
  PlaybackPosition? _currentPosition;

  @override
  void dispose() {
    for (final _LocalScore score in _scores) {
      score.document.close();
    }
    super.dispose();
  }

  Future<void> _upload() async {
    if (_scores.length >= _maxScores) {
      _toast('악보는 최대 $_maxScores개까지 올릴 수 있습니다.');
      return;
    }

    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;

    final int remaining = _maxScores - _scores.length;
    final List<PlatformFile> files = picked.files.take(remaining).toList();
    if (picked.files.length > remaining) {
      _toast('남은 자리만큼 $remaining개만 추가합니다.');
    }

    setState(() => _uploading = true);
    try {
      for (final PlatformFile file in files) {
        final Uint8List? bytes = file.bytes;
        if (bytes == null) continue;

        final String digest = sha256.convert(bytes).toString();
        if (_scores.any((_LocalScore score) => score.id == digest)) {
          _toast('${file.name}은 이미 올라와 있습니다.');
          continue;
        }

        final ScorePdfDocument document = await openScorePdf(bytes);
        final LocalScoreAnalysis detectedAnalysis;
        try {
          detectedAnalysis =
              await _analyzer.analyze(document, fileName: file.name);
        } catch (error) {
          await document.close();
          await _showRejected(
            file.name,
            '악보 분석 중 오류가 발생했습니다: $error',
          );
          continue;
        }
        if (!detectedAnalysis.isUsable) {
          await document.close();
          await _showRejected(
            file.name,
            detectedAnalysis.failureReason ?? '이 악보의 마디 구조를 읽지 못했습니다.',
          );
          continue;
        }

        ScoreMatchResult? match;
        bool reviewConfirmed = false;
        LocalScoreAnalysis analysis = detectedAnalysis;
        List<LocalScoreAnalysis>? alignedAnalyses;
        if (_scores.isNotEmpty) {
          alignedAnalyses = _analyzer.alignPlaybackTimelines(
            <LocalScoreAnalysis>[
              for (final _LocalScore score in _scores)
                score.manuallyAdjusted
                    ? score.analysis.copyWith(map: score.map)
                    : score.detectedAnalysis,
              detectedAnalysis,
            ],
          );
          analysis = alignedAnalyses.last;
          match = _analyzer.compare(alignedAnalyses.first, analysis);
          if (match.rejected) {
            await document.close();
            await _showRejected(
              file.name,
              '${match.reason}\n'
              '일치 신뢰도 ${(match.confidence * 100).round()}%',
            );
            continue;
          }
          if (match.needsReview) {
            reviewConfirmed = await _confirmAmbiguousMatch(
              file.name,
              analysis,
              match,
            );
            if (!reviewConfirmed) {
              await document.close();
              continue;
            }
          }
        }

        final double aspectRatio = await document.pageAspectRatio(0);
        final Uint8List? image = await document.renderPage(0);
        if (!mounted) {
          await document.close();
          return;
        }

        setState(() {
          if (alignedAnalyses != null) {
            for (int index = 0; index < _scores.length; index++) {
              _scores[index]
                ..analysis = alignedAnalyses[index]
                ..map = alignedAnalyses[index].map;
            }
          }
          _scores.add(
            _LocalScore(
              id: digest,
              fileName: file.name,
              title: analysis.title.isNotEmpty ? analysis.title : file.name,
              document: document,
              pageCount: document.pagesCount,
              image: image,
              aspectRatio: aspectRatio,
              map: analysis.map,
              analysis: analysis,
              detectedAnalysis: detectedAnalysis,
              matchConfidence: match?.confidence,
              reviewConfirmed: reviewConfirmed,
            ),
          );
        });
      }
    } catch (error) {
      if (mounted) _toast('PDF를 열지 못했습니다: $error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _selectPosition(_LocalScore source, double x, double y) async {
    final List<PlaybackPosition> positions = source.map.playbackPositionsAt(
      source.page,
      x,
      y,
    );
    if (positions.isEmpty) {
      _toast(source.map.isEmpty
          ? '이 악보는 먼저 줄 시작 위치를 지정해야 합니다.'
          : '악보가 있는 영역을 눌러주세요.');
      return;
    }

    final PlaybackPosition? position = positions.length == 1
        ? positions.single
        : await _choosePlaybackOccurrence(positions);
    if (position == null || !mounted) return;

    setState(() => _currentPosition = position);
    await Future.wait<void>(
      _scores.map(
        (_LocalScore score) =>
            _moveToPlaybackPosition(score, position.timeline),
      ),
    );
  }

  Future<PlaybackPosition?> _choosePlaybackOccurrence(
    List<PlaybackPosition> positions,
  ) {
    final int physicalMeasure = positions.first.physicalMeasure.floor();
    return showDialog<PlaybackPosition>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('어느 $physicalMeasure마디인가요?'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '도돌이표 때문에 같은 인쇄 마디가 연주 중 여러 번 나옵니다.',
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < positions.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    title: Text(i == 0
                        ? '원래 $physicalMeasure마디'
                        : '도돌이 후 $physicalMeasure마디'),
                    subtitle: Text(
                      '연주 순서 ${positions[i].timeline.floor() + 1}번째 마디',
                    ),
                    onTap: () => Navigator.of(context).pop(positions[i]),
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  Future<void> _moveToPlaybackPosition(
    _LocalScore score,
    double timeline,
  ) async {
    final MeasureBand? band = score.map.bandOfPlayback(timeline);
    if (band == null) {
      if (mounted && _scores.contains(score)) {
        setState(() => score.highlight = null);
      }
      return;
    }

    if (band.page != score.page) {
      await _renderPage(score, band.page);
    }
    if (!mounted || !_scores.contains(score)) return;
    setState(() => score.highlight = band);
  }

  Future<void> _renderPage(_LocalScore score, int page) async {
    if (page < 0 || page >= score.pageCount) return;
    final int renderToken = ++score.renderToken;
    setState(() => score.loading = true);
    try {
      final double aspectRatio = await score.document.pageAspectRatio(page);
      final Uint8List? image = await score.document.renderPage(page);
      if (!mounted ||
          !_scores.contains(score) ||
          renderToken != score.renderToken) {
        return;
      }
      setState(() {
        score.page = page;
        score.image = image;
        score.aspectRatio = aspectRatio;
      });
    } finally {
      if (mounted &&
          _scores.contains(score) &&
          renderToken == score.renderToken) {
        setState(() => score.loading = false);
      }
    }
  }

  Future<void> _addAnchor(_LocalScore score, double _, double y) async {
    final double startGuess = score.map.nextMeasureGuess();
    debugPrint('[anchor] opening add dialog: page=${score.page}, y=$y');
    final AnchorRangeResult? edit = await showDialog<AnchorRangeResult>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AnchorRangeDialog(
        start: startGuess,
        end: startGuess + 4,
        canDelete: false,
      ),
    );
    if (edit == null || !mounted || !_scores.contains(score)) return;

    debugPrint('[anchor] adding range ${edit.start}~${edit.end}');
    setState(() {
      score.manuallyAdjusted = true;
      score.map = MeasureMap(<ScoreAnchor>[
        ...score.map.anchors,
        ScoreAnchor(
          page: score.page,
          y: y,
          measure: edit.start,
          endMeasure: edit.end,
          xStart: 0.091,
          xEnd: 0.960,
        ),
      ]);
    });
  }

  Future<void> _editAnchor(_LocalScore score, ScoreAnchor anchor) async {
    debugPrint('[anchor] opening edit dialog: $anchor');
    final AnchorRangeResult? edit = await showDialog<AnchorRangeResult>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AnchorRangeDialog(
        start: anchor.measure,
        end: anchor.endMeasure ?? anchor.measure + 4,
        canDelete: true,
      ),
    );
    if (edit == null || !mounted || !_scores.contains(score)) return;

    final List<ScoreAnchor> anchors = score.map.anchors
        .where((ScoreAnchor item) => !identical(item, anchor))
        .toList();
    if (!edit.delete) {
      anchors.add(
        anchor.copyWith(measure: edit.start, endMeasure: edit.end),
      );
    }
    setState(() {
      score.manuallyAdjusted = true;
      score.map = MeasureMap(anchors);
    });
  }

  Future<void> _showRejected(String fileName, String reason) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: const Icon(Icons.do_not_disturb_alt_outlined),
        title: const Text('악보 업로드 거절'),
        content: Text('$fileName\n\n$reason'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmAmbiguousMatch(
    String fileName,
    LocalScoreAnalysis analysis,
    ScoreMatchResult match,
  ) async {
    if (!mounted) return false;
    final String contentScore = match.contentCompared
        ? '${(match.contentSimilarity * 100).round()}%'
        : '비교 자료 없음';
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) => AlertDialog(
            icon: const Icon(Icons.rule_folder_outlined),
            title: const Text('같은 곡인지 확인해 주세요'),
            content: Text(
              '$fileName\n\n'
              '분석 제목: ${analysis.title}\n'
              '제목 ${(match.titleSimilarity * 100).round()}% · '
              '내용 $contentScore · '
              '마디 구조 ${(match.structureSimilarity * 100).round()}%\n\n'
              '${match.reason}\n'
              '같은 곡이 맞다면 연결할 수 있습니다.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('같은 곡으로 연결'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _remove(_LocalScore score) async {
    setState(() => _scores.remove(score));
    await score.document.close();
    if (_scores.isEmpty && mounted) setState(() => _currentPosition = null);
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  static String _formatMeasure(double measure) =>
      measure == measure.roundToDouble()
          ? '${measure.round()}'
          : measure.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('BarLink'),
            Text(
              '로컬 악보 동기화 · 서버 사용 안 함',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: <Widget>[
          if (_currentPosition != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(_positionLabel(_currentPosition!)),
              ),
            ),
          IconButton(
            tooltip: 'PDF 악보 추가 (${_scores.length}/$_maxScores)',
            onPressed:
                _uploading || _scores.length >= _maxScores ? null : _upload,
            icon: const Icon(Icons.add_to_photos_outlined),
          ),
        ],
      ),
      body: _scores.isEmpty ? _emptyState() : _scoreGrid(),
    );
  }

  static String _positionLabel(PlaybackPosition position) {
    final String measure = '${_formatMeasure(position.physicalMeasure)}마디';
    if (position.occurrenceCount > 1) {
      final String occurrence = position.occurrence == 1 ? '원래' : '도돌이 후';
      return '$measure · $occurrence · 연주 ${position.timeline.floor() + 1}번째';
    }
    if (position.repeatPass > 0) {
      return '$measure · 반복 ${position.repeatPass}회';
    }
    return measure;
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.library_music_outlined, size: 72),
            const SizedBox(height: 20),
            const Text(
              '악보를 최대 6개 올려보세요',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '한 악보의 위치를 누르면 나머지 악보가 같은 마디로 이동합니다.\n'
              '파일과 위치 정보는 이 기기에서만 사용됩니다.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _uploading ? null : _upload,
              icon: const Icon(Icons.upload_file),
              label: Text(_uploading ? '불러오는 중…' : 'PDF 악보 선택'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scoreGrid() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 900 ? 2 : 1;
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: columns == 1 ? 560 : 520,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: _scores.length,
          itemBuilder: (BuildContext context, int index) =>
              _scoreCard(_scores[index]),
        );
      },
    );
  }

  Widget _scoreCard(_LocalScore score) {
    final String repeatInfo =
        score.map.hasRepeats ? ' · 도돌이 ${score.map.repeats.length}개' : '';
    final String analysisStatus = score.map.isEmpty
        ? '연결 정보 없음 · 자 아이콘으로 줄 위치 지정'
        : score.manuallyAdjusted
            ? '수동 보정됨 · ${score.map.length}개 시스템'
            : score.reviewConfirmed
                ? '사용자 확인 · 같은 곡 · ${score.map.length}개 시스템'
                : score.matchConfidence == null
                    ? '기준 악보 · 자동 분석 · ${score.map.length}개 시스템'
                    : '같은 곡 ${(score.matchConfidence! * 100).round()}% · '
                        '자동 연결 · ${score.map.length}개 시스템';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            dense: true,
            title: Text(
              score.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '$analysisStatus$repeatInfo',
              style: TextStyle(
                color: score.map.isEmpty
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: score.editing ? '위치 지정 끝내기' : '줄 위치 지정',
                  onPressed: () =>
                      setState(() => score.editing = !score.editing),
                  icon: Icon(score.editing ? Icons.done : Icons.straighten),
                ),
                IconButton(
                  tooltip: '악보 제거',
                  onPressed: () => _remove(score),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (score.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ScorePageView(
              key: ValueKey<String>(score.id),
              image: score.image,
              map: score.map,
              page: score.page,
              aspectRatio: score.aspectRatio,
              highlight: score.highlight,
              editing: score.editing,
              onTapPosition: score.editing
                  ? (double x, double y) => _addAnchor(score, x, y)
                  : (double x, double y) => _selectPosition(score, x, y),
              onTapAnchor: (ScoreAnchor anchor) => _editAnchor(score, anchor),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton(
                onPressed: score.page > 0 && !score.loading
                    ? () => _renderPage(score, score.page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${score.page + 1} / ${score.pageCount}'),
              IconButton(
                onPressed: score.page < score.pageCount - 1 && !score.loading
                    ? () => _renderPage(score, score.page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocalScore {
  final String id;
  final String fileName;
  final String title;
  final ScorePdfDocument document;
  final int pageCount;
  final LocalScoreAnalysis detectedAnalysis;
  final double? matchConfidence;
  final bool reviewConfirmed;

  LocalScoreAnalysis analysis;
  MeasureMap map;
  Uint8List? image;
  int page = 0;
  double aspectRatio;
  MeasureBand? highlight;
  bool loading = false;
  bool editing = false;
  bool manuallyAdjusted = false;
  int renderToken = 0;

  _LocalScore({
    required this.id,
    required this.fileName,
    required this.title,
    required this.document,
    required this.pageCount,
    required this.image,
    required this.aspectRatio,
    required this.map,
    required this.analysis,
    required this.detectedAnalysis,
    required this.matchConfidence,
    required this.reviewConfirmed,
  });
}
