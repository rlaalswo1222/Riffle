import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_constants.dart';

/// 방 안의 실시간 연결.
///
/// 오가는 것은 마디 번호뿐이다. 좌표는 보내지 않는다 — 받는 쪽 악보가
/// 다르므로 아무 뜻이 없다.
class WsService {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;

  /// 누군가 악보의 한 지점을 가리켰다.
  void Function(double measure, String from)? onPoint;

  /// 누군가 악보를 새로 올렸다.
  void Function(String? part)? onScoreUploaded;

  void Function(String userName, bool joined)? onPresence;

  bool get isConnected => _channel != null;

  void connect({
    required String roomId,
    required String userName,
    required String roomToken,
  }) {
    disconnect();

    final Uri uri = Uri.parse(
      '${ApiConstants.wsBaseUrl}/api/ws/room/$roomId'
      '?user_name=${Uri.encodeComponent(userName)}'
      '&room_token=${Uri.encodeComponent(roomToken)}',
    );
    _channel = WebSocketChannel.connect(uri);

    _sub = _channel!.stream.listen(
      _handle,
      onDone: disconnect,
      onError: (Object _) => disconnect(),
    );

    // 중간의 공유기나 통신사 장비가 조용한 연결을 임의로 끊는다.
    // 연습 중에는 몇 분씩 아무것도 안 보낼 수 있어서 주기적으로 깨운다.
    _ping = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _send(<String, dynamic>{'type': 'ping'}),
    );
  }

  void _handle(dynamic raw) {
    final Map<String, dynamic> data =
        jsonDecode(raw as String) as Map<String, dynamic>;
    switch (data['type']) {
      case 'point':
        final num? measure = data['measure'] as num?;
        if (measure != null) {
          onPoint?.call(measure.toDouble(), data['from'] as String? ?? '');
        }
      case 'score_uploaded':
        onScoreUploaded?.call(data['part'] as String?);
      case 'user_joined':
        onPresence?.call(data['user_name'] as String? ?? '', true);
      case 'user_left':
        onPresence?.call(data['user_name'] as String? ?? '', false);
    }
  }

  void _send(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // 끊긴 연결에 쓰는 것뿐이다. 화면까지 세울 이유가 없다.
    }
  }

  /// "여기" 라고 알린다.
  void point(double measure, String? part) => _send(<String, dynamic>{
        'type': 'point',
        'measure': measure,
        'part': part,
      });

  void announceScore(String? part) =>
      _send(<String, dynamic>{'type': 'score_uploaded', 'part': part});

  void disconnect() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }
}
