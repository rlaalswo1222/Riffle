import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'chroma_stream.dart';

/// 유튜브 검색 결과 하나.
class OriginalCandidate {
  final String id;
  final String title;
  final String channel;
  final Duration? duration;

  const OriginalCandidate(this.id, this.title, this.channel, this.duration);

  /// 유튜브 뮤직이 자동으로 올리는 공식 음원 채널("아티스트 - Topic").
  /// 스튜디오 원곡이라 기준으로 가장 좋다. 직캠·커버는 템포와 편곡이 다르다.
  bool get official => channel.endsWith(' - Topic');
}

/// 원곡 음원 찾기·내려받기·풀기.
///
/// 검색은 앱 안 라이브러리로 한다. 내려받기는 그 라이브러리가 유튜브 보안
/// 검사를 통과하지 못해서, 앱에 넣은 yt-dlp(안드로이드 쪽)로 한다.
class OriginalAudio {
  static const MethodChannel _channel = MethodChannel('barlink/original');

  /// 악보 제목·가수로 검색한다. 공식 음원을 앞에, 그다음은 악보로 계산한
  /// 곡 길이에 가까운 순서로 둔다.
  static OriginalSearchSession startSearch(
    String title,
    String artist, {
    Duration? expected,
    http.Client? httpClient,
  }) {
    final YoutubeExplode yt =
        YoutubeExplode(httpClient: _SearchHttpClient(httpClient));
    VideoSearchList? cursor;
    bool started = false;
    return OriginalSearchSession(
      expected: expected,
      close: yt.close,
      nextPage: () async {
        final VideoSearchList? page = started
            ? await cursor!.nextPage()
            : await yt.search.search('$artist $title'.trim());
        if (page == null) return null;
        cursor = page;
        started = true;
        return <OriginalCandidate>[
          for (final Video v in page)
            OriginalCandidate(v.id.value, v.title, v.author, v.duration),
        ];
      },
    );
  }

  /// 오디오만 [dir]에 내려받고 파일 경로를 돌려준다. 처음 한 번은 yt-dlp를
  /// 준비하느라 몇 초 더 걸린다.
  static Future<String> download(
    String videoId,
    String dir, {
    void Function(double percent)? onProgress,
  }) async {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'progress') {
        onProgress?.call((call.arguments as num).toDouble());
      }
    });
    try {
      final String? path =
          await _channel.invokeMethod<String>('download', <String, dynamic>{
        'url': 'https://www.youtube.com/watch?v=$videoId',
        'dir': dir,
      });
      return path!;
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  /// 음원 파일(m4a·mp3 등)을 추종기와 같은 22050Hz 모노 16비트 PCM 파일로 푼다.
  static Future<void> decodeToFile(String path, String out) async {
    await _channel.invokeMethod<int>('decode', <String, dynamic>{
      'path': path,
      'out': out,
      'rate': ChromaStream.sampleRate,
    });
  }

  /// [decodeToFile]이 만든 PCM 파일을 -1~1 샘플로 읽는다. 별도 isolate에서도 쓴다.
  static Float64List readPcm(String path) {
    final Uint8List bytes = File(path).readAsBytesSync();
    final ByteData data = ByteData.sublistView(bytes);
    final Float64List samples = Float64List(bytes.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}

/// Keeps the search cursor alive while the picker is open. A null page means
/// the service has no more results; an empty page can still have a continuation.
class OriginalSearchSession extends ChangeNotifier {
  final Future<List<OriginalCandidate>?> Function() _nextPage;
  final void Function() _close;
  final Duration? expected;
  final List<OriginalCandidate> _candidates = <OriginalCandidate>[];
  final Set<String> _ids = <String>{};
  late final List<OriginalCandidate> candidates =
      UnmodifiableListView<OriginalCandidate>(_candidates);
  bool loading = false;
  Object? error;
  bool get failed => error != null;
  bool hasMore = true;
  bool _disposed = false;
  Future<void>? _pending;

  OriginalSearchSession({
    required Future<List<OriginalCandidate>?> Function() nextPage,
    required void Function() close,
    this.expected,
  })  : _nextPage = nextPage,
        _close = close;

  Future<void> loadMore() {
    if (_disposed || !hasMore) return Future<void>.value();
    if (_pending != null) return _pending!;
    final Completer<void> done = Completer<void>();
    _pending = done.future;
    loading = true;
    error = null;
    notifyListeners();
    unawaited(_loadMore(done));
    return done.future;
  }

  Future<void> _loadMore(Completer<void> done) async {
    try {
      final List<OriginalCandidate>? page = await _nextPage();
      if (_disposed) return;
      if (page == null) {
        hasMore = false;
      } else {
        final List<OriginalCandidate> fresh =
            page.where((OriginalCandidate c) => _ids.add(c.id)).toList();
        final Duration? target = expected;
        int gap(OriginalCandidate c) => target == null || c.duration == null
            ? 1 << 30
            : (c.duration! - target).inSeconds.abs();
        // Sort each new batch without moving rows that are already on screen.
        fresh.sort((OriginalCandidate a, OriginalCandidate b) {
          if (a.official != b.official) return a.official ? -1 : 1;
          return gap(a).compareTo(gap(b));
        });
        _candidates.addAll(fresh);
      }
    } catch (failure) {
      if (!_disposed) error = failure;
    } finally {
      _pending = null;
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
      done.complete();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _close();
    super.dispose();
  }
}

class _SearchHttpClient extends YoutubeHttpClient {
  _SearchHttpClient(super.httpClient);

  @override
  Future<Map<String, dynamic>> sendContinuation(
    String action,
    String token, {
    Map<String, String>? headers,
  }) async {
    final Map<String, dynamic> data =
        await super.sendContinuation(action, token, headers: headers);
    // youtube_explode_dart 3.1.0 treats a missing estimate as the end, even
    // when a continuation token remains. Search continuation responses can
    // omit this field; the actual token still determines the end of the list.
    if (action == 'search') data.putIfAbsent('estimatedResults', () => '1');
    return data;
  }
}
