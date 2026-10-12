import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/score_anchor.dart';
import '../models/score_info.dart';
import 'api_constants.dart';

/// 서버와 주고받는 것 전부.
///
/// 방 열쇠([roomToken])는 들어올 때 한 번 받아 두고 이후 모든 요청에
/// 실어 보낸다. EnsembleSync 와 같은 헤더 이름을 쓴다.
class ApiService {
  static String? roomToken;

  static Map<String, String> get _headers => <String, String>{
        'Content-Type': 'application/json',
        if (roomToken != null) 'X-Room-Token': roomToken!,
      };

  static Uri _uri(String path) => Uri.parse('${ApiConstants.baseUrl}$path');

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final http.Response res = await http.post(
      _uri(path),
      headers: _headers,
      body: jsonEncode(body),
    );
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> createRoom({
    required String roomName,
    required String nickname,
    required String part,
  }) =>
      _post('/api/room/create', <String, dynamic>{
        'room_name': roomName,
        'nickname': nickname,
        'part': part,
      });

  static Future<Map<String, dynamic>> joinRoom({
    required String roomCode,
    required String nickname,
    required String part,
  }) =>
      _post('/api/room/join', <String, dynamic>{
        'room_code': roomCode,
        'nickname': nickname,
        'part': part,
      });

  /// 방 안의 악보를 파트별로 전부 가져온다.
  static Future<List<ScoreInfo>> listScores(String roomId) async {
    final http.Response res =
        await http.get(_uri('/api/score/$roomId/list'), headers: _headers);
    final Map<String, dynamic> body =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (body['status'] != 200) return <ScoreInfo>[];
    return (body['scores'] as List<dynamic>)
        .map((dynamic e) => ScoreInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<Map<String, dynamic>> uploadScore({
    required String roomId,
    required String part,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final http.MultipartRequest req = http.MultipartRequest(
      'POST',
      _uri('/api/score/$roomId/upload'),
    )
      ..fields['part'] = part
      ..files
          .add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    if (roomToken != null) req.headers['X-Room-Token'] = roomToken!;

    final http.Response res = await http.Response.fromStream(await req.send());
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  static Future<List<ScoreAnchor>> getAnchors(String scoreId) async {
    final http.Response res =
        await http.get(_uri('/api/score/$scoreId/anchors'), headers: _headers);
    final Map<String, dynamic> body =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (body['status'] != 200) return <ScoreAnchor>[];
    return (body['anchors'] as List<dynamic>)
        .map((dynamic e) => ScoreAnchor.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 앵커를 통째로 갈아끼운다.
  ///
  /// 하나씩 고치는 API 를 두지 않는다. 편집 중에는 여러 개를 옮기고
  /// 지우게 되는데, 그 차이를 서버와 맞춰 가는 것보다 지금 화면에 있는
  /// 것을 그대로 보내는 편이 덜 틀린다.
  static Future<bool> putAnchors(
    String scoreId,
    List<ScoreAnchor> anchors,
  ) async {
    final http.Response res = await http.put(
      _uri('/api/score/$scoreId/anchors'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'anchors': anchors.map((ScoreAnchor a) => a.toJson()).toList(),
      }),
    );
    final Map<String, dynamic> body =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return body['status'] == 200;
  }

  static Future<Uint8List?> download(String url) async {
    final http.Response res = await http.get(Uri.parse(url));
    return res.statusCode == 200 ? res.bodyBytes : null;
  }
}
