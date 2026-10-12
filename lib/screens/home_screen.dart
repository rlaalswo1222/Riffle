import 'package:flutter/material.dart';

import '../models/part.dart';
import '../services/api_service.dart';
import 'session_screen.dart';

/// 방을 만들거나 코드로 들어간다.
///
/// 로그인이 없다. EnsembleSync 와 같은 방식이다 — 합주하러 모인 사람들이
/// 각자 계정을 만들고 있을 이유가 없다.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _nickname = TextEditingController();
  final TextEditingController _roomName = TextEditingController();
  final TextEditingController _roomCode = TextEditingController();

  String _part = Part.all.first.id;
  bool _busy = false;

  @override
  void dispose() {
    _nickname.dispose();
    _roomName.dispose();
    _roomCode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    if (_nickname.text.trim().isEmpty) {
      _toast('닉네임을 입력해주세요.');
      return;
    }
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> res = await call();
      if (!mounted) return;
      if (res['status'] != 200) {
        _toast(res['message'] as String? ?? '실패했습니다.');
        return;
      }
      ApiService.roomToken = res['room_token'] as String;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(
            roomId: res['room_id'] as String,
            roomCode: res['room_code'] as String? ??
                _roomCode.text.trim().toUpperCase(),
            nickname: _nickname.text.trim(),
            part: res['part'] as String,
          ),
        ),
      );
    } catch (e) {
      _toast('서버에 닿지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text(
                    'BarLink',
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '각자 다른 악보를 보면서 같은 마디를 가리킨다',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nickname,
                    decoration: const InputDecoration(
                      labelText: '닉네임',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('내 파트'),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: Part.all
                        .map((Part p) => ChoiceChip(
                              label: Text(p.label),
                              selected: _part == p.id,
                              onSelected: (_) => setState(() => _part = p.id),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _roomCode,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: '방 코드 6자리',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => ApiService.joinRoom(
                              roomCode: _roomCode.text.trim().toUpperCase(),
                              nickname: _nickname.text.trim(),
                              part: _part,
                            )),
                    child: const Text('들어가기'),
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _roomName,
                    decoration: const InputDecoration(
                      labelText: '새 방 이름 (곡 제목)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => ApiService.createRoom(
                              roomName: _roomName.text.trim(),
                              nickname: _nickname.text.trim(),
                              part: _part,
                            )),
                    child: const Text('방 만들기'),
                  ),
                  if (_busy) ...<Widget>[
                    const SizedBox(height: 24),
                    const Center(child: CircularProgressIndicator()),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
