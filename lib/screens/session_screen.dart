import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/measure_map.dart';
import '../models/part.dart';
import '../models/score_anchor.dart';
import '../models/score_info.dart';
import '../services/api_service.dart';
import '../services/score_pdf_document.dart';
import '../services/score_pdf_renderer.dart';
import '../services/ws_service.dart';
import '../widgets/score_page_view.dart';

/// 합주 화면.
///
/// 각자 자기 파트 악보만 본다. 오가는 것은 마디 번호뿐이라, 옆 사람이
/// 몇 페이지를 보고 있든 상관이 없다.
class SessionScreen extends StatefulWidget {
  final String roomId;
  final String roomCode;
  final String nickname;
  final String part;

  const SessionScreen({
    super.key,
    required this.roomId,
    required this.roomCode,
    required this.nickname,
    required this.part,
  });

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final WsService _ws = WsService();

  List<ScoreInfo> _scores = <ScoreInfo>[];
  ScoreInfo? _mine;

  ScorePdfDocument? _document;
  Uint8List? _pageImage;
  int _page = 0;
  int _pageCount = 1;
  double _pageAspectRatio = 1 / 1.41421356237;

  MeasureMap _map = MeasureMap(const <ScoreAnchor>[]);

  MeasureBand? _highlight;
  String _highlightFrom = '';

  bool _editing = false;
  bool _dirty = false;
  bool _loading = true;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _ws
      ..onPoint = _onPoint
      // 화살표로 쓰면 안 된다. 뒤따르는 ..connect 가 이 함수 몸통의
      // _loadScores() 에 붙어버려서, 연결이 영영 열리지 않는다.
      ..onScoreUploaded = (String? _) {
        _loadScores();
      }
      ..connect(
        roomId: widget.roomId,
        userName: widget.nickname,
        roomToken: ApiService.roomToken ?? '',
      );
    _loadScores();
  }

  @override
  void dispose() {
    _ws.disconnect();
    _document?.close();
    super.dispose();
  }

  // 악보 불러오기 -----------------------------------------------------

  Future<void> _loadScores() async {
    setState(() => _loading = true);
    final List<ScoreInfo> scores = await ApiService.listScores(widget.roomId);
    if (!mounted) return;

    ScoreInfo? mine;
    for (final ScoreInfo s in scores) {
      if (s.part == widget.part) mine = s;
    }

    final bool changed = mine?.scoreId != _mine?.scoreId;
    setState(() {
      _scores = scores;
      _mine = mine;
    });

    if (mine == null) {
      setState(() => _loading = false);
      return;
    }
    if (changed) {
      await _openScore(mine);
    }
    await _loadAnchors(mine.scoreId);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openScore(ScoreInfo score) async {
    setState(() => _status = '악보 여는 중');
    final Uint8List? bytes = await ApiService.download(score.fileUrl);
    if (bytes == null || !mounted) {
      setState(() => _status = '악보를 받지 못했습니다.');
      return;
    }

    await _document?.close();
    _document = null;

    if (score.isPdf) {
      final ScorePdfDocument doc = await openScorePdf(bytes);
      if (!mounted) return;
      _document = doc;
      _pageCount = doc.pagesCount;
      _page = 0;
      await _renderPage(0);
    } else {
      // 이미지 악보는 한 장짜리 PDF 와 같다.
      setState(() {
        _pageCount = 1;
        _page = 0;
        _pageImage = bytes;
      });
    }
    if (mounted) setState(() => _status = '');
  }

  Future<void> _renderPage(int page) async {
    final ScorePdfDocument? doc = _document;
    if (doc == null) return;
    final double aspectRatio = await doc.pageAspectRatio(page);
    final Uint8List? image = await doc.renderPage(page);
    if (!mounted) return;
    setState(() {
      _page = page;
      _pageImage = image;
      _pageAspectRatio = aspectRatio;
    });
  }

  Future<void> _loadAnchors(String scoreId) async {
    final List<ScoreAnchor> anchors = await ApiService.getAnchors(scoreId);
    if (!mounted) return;
    setState(() {
      _map = MeasureMap(anchors);
      _dirty = false;
    });
  }

  // 위치 주고받기 -----------------------------------------------------

  /// 내 악보를 눌렀다. 마디로 바꿔서 알린다.
  void _tapToPoint(double x, double y) {
    final double? measure = _map.measureAt(_page, x, y);
    if (measure == null) {
      _toast(_map.isEmpty
          ? '먼저 마디를 찍어야 위치를 공유할 수 있습니다.'
          : '이 위쪽은 아직 마디가 정해지지 않았습니다.');
      return;
    }
    _ws.point(measure, widget.part);
    setState(() {
      _highlight = _map.bandOf(measure);
      _highlightFrom = '나';
    });
  }

  /// 누가 가리켰다. 내 악보에서 그 자리를 찾는다.
  Future<void> _onPoint(double measure, String from) async {
    final MeasureBand? band = _map.bandOf(measure);
    if (band == null) {
      setState(() {
        _highlight = null;
        _highlightFrom = '';
        _status = _map.isEmpty
            ? '$from 님이 ${_fmt(measure)}마디를 가리켰습니다. 내 악보에도 마디를 찍어야 따라갈 수 있습니다.'
            : '$from 님이 가리킨 ${_fmt(measure)}마디는 내 악보에 없습니다.';
      });
      return;
    }

    if (band.page != _page) {
      await _renderPage(band.page);
    }
    if (!mounted) return;
    setState(() {
      _highlight = band;
      _highlightFrom = from;
      _status = '';
    });
  }

  static String _fmt(double m) =>
      m == m.roundToDouble() ? '${m.round()}' : m.toStringAsFixed(1);

  // 마디 찍기 ---------------------------------------------------------

  void _addAnchor(double x, double y) {
    final double measure = _map.nextMeasureGuess();
    setState(() {
      _map = MeasureMap(<ScoreAnchor>[
        ..._map.anchors,
        ScoreAnchor(page: _page, y: y, measure: measure),
      ]);
      _dirty = true;
    });
  }

  Future<void> _editAnchor(ScoreAnchor anchor) async {
    final TextEditingController controller =
        TextEditingController(text: _fmt(anchor.measure));

    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('이 줄의 첫 마디'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Text('삭제'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (action == null || action == 'cancel') return;

    final List<ScoreAnchor> next = _map.anchors
        .where((ScoreAnchor a) => a.page != anchor.page || a.y != anchor.y)
        .toList();

    if (action == 'save') {
      final double? measure = double.tryParse(controller.text.trim());
      if (measure == null) {
        _toast('숫자를 입력해주세요.');
        return;
      }
      next.add(anchor.copyWith(measure: measure));
    }

    setState(() {
      _map = MeasureMap(next);
      _dirty = true;
    });
  }

  Future<void> _saveAnchors() async {
    final ScoreInfo? mine = _mine;
    if (mine == null) return;
    final bool ok = await ApiService.putAnchors(mine.scoreId, _map.anchors);
    if (!mounted) return;
    if (ok) {
      setState(() => _dirty = false);
      _toast('마디 ${_map.length}개를 저장했습니다.');
      _loadScores();
    } else {
      _toast('저장하지 못했습니다.');
    }
  }

  // 악보 올리기 -------------------------------------------------------

  Future<void> _uploadScore() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['pdf', 'png', 'jpg', 'jpeg'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final PlatformFile file = picked.files.first;
    if (file.bytes == null) return;

    setState(() => _status = '올리는 중');
    final Map<String, dynamic> res = await ApiService.uploadScore(
      roomId: widget.roomId,
      part: widget.part,
      fileName: file.name,
      bytes: file.bytes!,
    );
    if (!mounted) return;
    setState(() => _status = '');

    if (res['status'] != 200) {
      _toast(res['message'] as String? ?? '올리지 못했습니다.');
      return;
    }
    _ws.announceScore(widget.part);
    await _loadScores();
    if (res['preset_linked'] == true) {
      _toast('이 악보의 마디 위치를 자동으로 연결했습니다.');
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  // 화면 --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${Part.labelOf(widget.part)} · ${widget.roomCode}'),
        actions: <Widget>[
          if (_mine != null)
            IconButton(
              tooltip: _editing ? '찍기 끝내기' : '마디 찍기',
              icon: Icon(_editing ? Icons.done : Icons.straighten),
              onPressed: () => setState(() => _editing = !_editing),
            ),
          if (_editing && _dirty)
            IconButton(
              tooltip: '저장',
              icon: const Icon(Icons.save),
              onPressed: _saveAnchors,
            ),
          IconButton(
            tooltip: '악보 올리기',
            icon: const Icon(Icons.upload_file),
            onPressed: _uploadScore,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _banner(),
          Expanded(child: _body()),
          if (_mine != null) _pageBar(),
        ],
      ),
    );
  }

  Widget _banner() {
    if (_status.isNotEmpty) {
      return _bar(_status, Theme.of(context).colorScheme.errorContainer);
    }
    if (_editing) {
      return _bar(
        _map.isEmpty
            ? '줄이 시작하는 곳을 위에서부터 차례로 누르세요. 마디 번호는 알아서 이어집니다.'
            : '줄 시작을 누르면 추가, 초록 선을 누르면 수정 · ${_map.length}개',
        const Color(0xFFE6F4EA),
      );
    }
    final MeasureBand? band = _highlight;
    if (band != null) {
      return _bar(
        '$_highlightFrom → ${_fmt(band.startMeasure)}마디부터',
        const Color(0xFFE8EEFF),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _bar(String text, Color background) => Container(
        width: double.infinity,
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(text),
      );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_mine == null) {
      final String others =
          _scores.map((ScoreInfo s) => Part.labelOf(s.part)).join(', ');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('${Part.labelOf(widget.part)} 악보가 아직 없습니다.'),
              const SizedBox(height: 4),
              Text(
                others.isEmpty ? '올라온 악보가 없습니다.' : '올라온 악보: $others',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _uploadScore,
                icon: const Icon(Icons.upload_file),
                label: const Text('내 파트 악보 올리기'),
              ),
            ],
          ),
        ),
      );
    }

    return ScorePageView(
      image: _pageImage,
      map: _map,
      page: _page,
      aspectRatio: _pageAspectRatio,
      highlight: _highlight,
      editing: _editing,
      onTapPosition: _editing ? _addAnchor : _tapToPoint,
      onTapAnchor: _editAnchor,
    );
  }

  Widget _pageBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              onPressed: _page > 0 ? () => _renderPage(_page - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text('${_page + 1} / $_pageCount'),
            IconButton(
              onPressed:
                  _page < _pageCount - 1 ? () => _renderPage(_page + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}
