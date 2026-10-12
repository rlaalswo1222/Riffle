import 'dart:async';

import 'package:flutter/material.dart';

import '../services/original_audio.dart';
import '../ui/toss.dart';

/// Appends search results as the user scrolls, keeping the chosen track.
class OriginalPicker extends StatefulWidget {
  static const String fromFile = 'file';
  final OriginalSearchSession search;

  const OriginalPicker({super.key, required this.search});

  @override
  State<OriginalPicker> createState() => _OriginalPickerState();
}

class _OriginalPickerState extends State<OriginalPicker> {
  final ScrollController _scroll = ScrollController();
  OriginalCandidate? _selected;

  @override
  void initState() {
    super.initState();
    _chooseDefault();
    widget.search.addListener(_changed);
    _scroll.addListener(_loadIfNearEnd);
    _scheduleLoad();
  }

  void _chooseDefault() {
    _selected ??= widget.search.candidates
            .where((OriginalCandidate c) => c.official)
            .firstOrNull ??
        widget.search.candidates.firstOrNull;
  }

  void _changed() {
    setState(_chooseDefault);
    _scheduleLoad();
  }

  void _scheduleLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadIfNearEnd();
    });
  }

  void _loadIfNearEnd() {
    if (!_scroll.hasClients || widget.search.failed || widget.search.loading) {
      return;
    }
    if (_scroll.position.extentAfter < 240) {
      unawaited(widget.search.loadMore());
    }
  }

  @override
  void dispose() {
    widget.search.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  static String _length(Duration? d) => d == null
      ? ''
      : ' · ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _footer() {
    if (widget.search.loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
            child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      );
    }
    if (widget.search.failed) {
      return Column(children: <Widget>[
        const Text('검색 결과를 불러오지 못했어요', style: Toss.caption),
        TextButton(
            onPressed: widget.search.loadMore, child: const Text('다시 시도')),
      ]);
    }
    if (widget.search.hasMore) {
      return TextButton(
        onPressed: widget.search.loadMore,
        child: const Text('더 보기'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
          child: Text(
        widget.search.candidates.isEmpty ? '검색 결과가 없어요' : '검색 결과를 모두 봤어요',
        style: Toss.caption,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    const List<List<Color>> tints = <List<Color>>[
      <Color>[Color(0xFFDCE7F7), Color(0xFFC5D2E6)],
      <Color>[Color(0xFFE7E2EF), Color(0xFFD3CCE0)],
      <Color>[Color(0xFFE3ECE5), Color(0xFFCCDBCF)],
    ];
    final List<OriginalCandidate> candidates = widget.search.candidates;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(children: <Widget>[
        Expanded(
            child: ListView.builder(
          controller: _scroll,
          itemCount: candidates.length + 1,
          itemBuilder: (BuildContext context, int i) {
            if (i == candidates.length) return _footer();
            final OriginalCandidate c = candidates[i];
            final bool selected = _selected?.id == c.id;
            return TossRow(
              leading: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(colors: tints[i % tints.length]),
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Color(0x8C191F28)),
              ),
              title: c.title,
              subtitle:
                  '${c.official ? '공식 음원 · ' : ''}${c.channel}${_length(c.duration)}',
              trailing: Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected ? Toss.blue : Toss.g300,
              ),
              onTap: () => setState(() => _selected = c),
            );
          },
        )),
        const SizedBox(height: 12),
        TossButton('이 음원으로 할게요',
            onPressed: _selected == null
                ? null
                : () => Navigator.pop(context, _selected)),
        TextButton(
          onPressed: () => Navigator.pop(context, OriginalPicker.fromFile),
          child: Text('휴대폰에 있는 파일 고르기',
              style: Toss.body.copyWith(color: Toss.g600)),
        ),
      ]),
    );
  }
}
