import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/score_library.dart';
import '../ui/toss.dart';
import 'prep_screen.dart';

/// 첫 화면: 악보함. 최근 곡을 크게, 나머지는 가볍게 줄 세운다.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<LibraryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<LibraryEntry> list = await ScoreLibrary.list();
    if (mounted) setState(() => _entries = list);
  }

  Future<void> _add() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
      withData: true,
    );
    final Uint8List? bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    final LibraryEntry e =
        await ScoreLibrary.add(bytes, picked!.files.single.name);
    await _open(e);
  }

  Future<void> _open(LibraryEntry e) async {
    e.openedAt = DateTime.now();
    await ScoreLibrary.save(e);
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PrepScreen(entry: e)));
    _reload();
  }

  Future<void> _remove(LibraryEntry e) async {
    final bool? ok = await showTossSheet<bool>(
      context: context,
      title: '악보함에서 지울까요?',
      description: '${e.title} · 원곡 분석 결과는 그대로 남아요',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TossButton('지우기', onPressed: () => Navigator.pop(context, true)),
          const SizedBox(height: 8),
          TossButton('취소',
              soft: true, onPressed: () => Navigator.pop(context, false)),
        ],
      ),
    );
    if (ok != true) return;
    await ScoreLibrary.remove(e.key);
    _reload();
  }

  static String _meta(LibraryEntry e) {
    if (!e.analyzed) return '아직 읽지 않았어요';
    final List<String> parts = <String>[
      if (e.artist.isNotEmpty) e.artist,
      '${e.measures}마디',
      if (e.repeats > 0)
        '도돌이 ${e.repeats}개'
      else if (e.bpm != null)
        '♩${e.bpm!.round()}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final List<LibraryEntry>? entries = _entries;
    return Scaffold(
      // 태블릿 가로 화면에서도 한 줄이 너무 길어지지 않게 가운데 폭을 제한한다.
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: <Widget>[
                        const Text(kAppName,
                            style: TextStyle(
                                fontFamily: Toss.font,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Toss.blue)),
                        const Spacer(),
                        if (entries != null && entries.isNotEmpty)
                          Text('${entries.length}곡', style: Toss.caption),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: entries == null
                      ? const Center(
                          child: CircularProgressIndicator(color: Toss.blue))
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: <Widget>[
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        entries.isEmpty
                                            ? '연주할 악보를\n먼저 넣어 주세요'
                                            : '오늘은 어떤 곡을\n연주할까요?',
                                        style: Toss.title.copyWith(fontSize: 26),
                                      ),
                                    ),
                                  ),
                                  // 앱 아이콘의 캐릭터가 악보 위로 빼꼼 내다본다.
                                  Image.asset('assets/images/riffle_mascot.png',
                                      width: 112),
                                ],
                              ),
                            ),
                            if (entries.isEmpty)
                              _emptyCard()
                            else ...<Widget>[
                              _recentCard(entries.first),
                              if (entries.length > 1) ...<Widget>[
                                const SizedBox(height: 12),
                                TossCard(
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 8, 20, 8),
                                  child: Column(
                                    children: <Widget>[
                                      for (final LibraryEntry e
                                          in entries.skip(1))
                                        TossRow(
                                          leading: TossIconBox(
                                            letter: e.title.isEmpty
                                                ? '?'
                                                : e.title.characters.first,
                                            accent: e.hasOriginal,
                                          ),
                                          title: e.title,
                                          subtitle: _meta(e),
                                          trailing: Text(
                                            e.hasOriginal ? '준비됨' : '원곡 없음',
                                            style: Toss.caption.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: e.hasOriginal
                                                  ? Toss.g500
                                                  : Toss.red,
                                            ),
                                          ),
                                          onTap: () => _open(e),
                                          onLongPress: () => _remove(e),
                                        ),
                                    ],
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(8, 10, 8, 0),
                                  child: Text('길게 누르면 악보함에서 지울 수 있어요',
                                      style: Toss.label),
                                ),
                              ],
                            ],
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: TossButton('PDF 악보 추가하기', onPressed: _add),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyCard() => const TossCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('코드가 적힌 PDF 악보면 돼요', style: Toss.subtitle),
            SizedBox(height: 6),
            Text(
              '녹음 버튼을 누르고 연주하면 지금 치는 마디를 짚어 주고, '
              '페이지도 알아서 넘겨요.',
              style: Toss.caption,
            ),
          ],
        ),
      );

  Widget _recentCard(LibraryEntry e) => GestureDetector(
        onLongPress: () => _remove(e),
        child: TossCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('최근에 연주한 곡', style: Toss.label),
              const SizedBox(height: 8),
              Text(e.title, style: Toss.subtitle.copyWith(fontSize: 20)),
              const SizedBox(height: 2),
              Text(_meta(e), style: Toss.caption),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Icon(
                      e.hasOriginal
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      size: 17,
                      color: e.hasOriginal ? Toss.blue : Toss.g400),
                  const SizedBox(width: 5),
                  Text(e.hasOriginal ? '원곡 연결됨' : '원곡 없음',
                      style: Toss.caption.copyWith(
                          fontWeight: FontWeight.w700,
                          color: e.hasOriginal ? Toss.blue : Toss.g500)),
                ],
              ),
              const SizedBox(height: 14),
              TossButton('이어서 연주하기',
                  soft: true, height: 48, onPressed: () => _open(e)),
            ],
          ),
        ),
      );
}
