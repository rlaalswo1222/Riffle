import 'package:flutter/material.dart';

class AnchorRangeResult {
  final double start;
  final double end;
  final bool delete;

  const AnchorRangeResult({
    required this.start,
    required this.end,
    this.delete = false,
  });
}

/// Samsung IME가 붙은 입력창을 안전하게 닫는 마디 범위 다이얼로그.
class AnchorRangeDialog extends StatefulWidget {
  final double start;
  final double end;
  final bool canDelete;

  const AnchorRangeDialog({
    super.key,
    required this.start,
    required this.end,
    required this.canDelete,
  });

  @override
  State<AnchorRangeDialog> createState() => _AnchorRangeDialogState();
}

class _AnchorRangeDialogState extends State<AnchorRangeDialog> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  final FocusNode _startFocus = FocusNode();
  final FocusNode _endFocus = FocusNode();

  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: _format(widget.start));
    _endController = TextEditingController(text: _format(widget.end));
  }

  @override
  void dispose() {
    _startFocus.dispose();
    _endFocus.dispose();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  void _save() {
    final double? start = double.tryParse(_startController.text.trim());
    final double? end = double.tryParse(_endController.text.trim());
    if (start == null || end == null || end <= start) {
      setState(() => _error = '끝 마디는 시작 마디보다 큰 숫자여야 합니다.');
      return;
    }
    _close(AnchorRangeResult(start: start, end: end));
  }

  void _delete() => _close(
        AnchorRangeResult(
          start: widget.start,
          end: widget.end,
          delete: true,
        ),
      );

  void _close(AnchorRangeResult? result) {
    if (_closing) return;
    setState(() => _closing = true);

    // 입력 연결이 살아 있는 채로 route와 controller를 동시에 정리하면 일부
    // Samsung IME에서 플랫폼 스레드가 멈출 수 있다. 먼저 포커스를 끊고,
    // Flutter가 TextInput.clearClient를 보낸 다음 프레임에 route를 닫는다.
    _startFocus.unfocus();
    _endFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('악보 줄의 마디 범위'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _startController,
            focusNode: _startFocus,
            enabled: !_closing,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _endFocus.requestFocus(),
            decoration: const InputDecoration(labelText: '시작 마디'),
          ),
          TextField(
            controller: _endController,
            focusNode: _endFocus,
            enabled: !_closing,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: '다음 줄 시작 마디 (끝 미포함)',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        if (widget.canDelete)
          TextButton(
            onPressed: _closing ? null : _delete,
            child: const Text('삭제'),
          ),
        TextButton(
          onPressed: _closing ? null : () => _close(null),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _closing ? null : _save,
          child: const Text('적용'),
        ),
      ],
    );
  }

  static String _format(double measure) => measure == measure.roundToDouble()
      ? '${measure.round()}'
      : measure.toStringAsFixed(1);
}
