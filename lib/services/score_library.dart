import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'score_analysis_cache.dart';

/// 악보함에 넣어 둔 악보 하나의 요약.
class LibraryEntry {
  final String key;
  final String fileName;
  String title;
  String artist;
  int measures;
  int chordMeasures;
  int repeats;
  double? bpm;
  bool hasOriginal;
  bool originalSkipped;

  /// 원곡으로 연결한 유튜브 영상 ID. 휴대폰 파일로 연결했거나 없으면 null.
  String? videoId;
  DateTime openedAt;

  LibraryEntry({
    required this.key,
    required this.fileName,
    required this.title,
    this.artist = '',
    this.measures = 0,
    this.chordMeasures = 0,
    this.repeats = 0,
    this.bpm,
    this.hasOriginal = false,
    this.originalSkipped = false,
    this.videoId,
    required this.openedAt,
  });

  /// 아직 한 번도 분석하지 않았나.
  bool get analyzed => measures > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'file_name': fileName,
        'title': title,
        'artist': artist,
        'measures': measures,
        'chord_measures': chordMeasures,
        'repeats': repeats,
        if (bpm != null) 'bpm': bpm,
        'has_original': hasOriginal,
        'original_skipped': originalSkipped,
        if (videoId != null) 'video_id': videoId,
        'opened_at': openedAt.toIso8601String(),
      };

  factory LibraryEntry.fromJson(Map<String, dynamic> j) => LibraryEntry(
        key: j['key'] as String,
        fileName: j['file_name'] as String? ?? '',
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        measures: (j['measures'] as num?)?.toInt() ?? 0,
        chordMeasures: (j['chord_measures'] as num?)?.toInt() ?? 0,
        repeats: (j['repeats'] as num?)?.toInt() ?? 0,
        bpm: (j['bpm'] as num?)?.toDouble(),
        hasOriginal: j['has_original'] as bool? ?? false,
        originalSkipped: j['original_skipped'] as bool? ?? false,
        videoId: j['video_id'] as String?,
        openedAt: DateTime.tryParse(j['opened_at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 한 번 연 PDF를 앱 안에 복사해 두고, 분석 요약을 함께 저장한다.
/// 매번 파일을 다시 고르지 않아도 되게 하려는 것이다.
class ScoreLibrary {
  static Future<Directory> _dir() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory('${base.path}/scores').create(recursive: true);
  }

  static String keyOf(Uint8List bytes) => sha256.convert(bytes).toString().substring(0, 16);

  static Future<List<LibraryEntry>> list() async {
    final Directory dir = await _dir();
    final List<LibraryEntry> out = <LibraryEntry>[];
    await for (final FileSystemEntity f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        out.add(LibraryEntry.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // 깨진 요약은 건너뛴다.
      }
    }
    out.sort((LibraryEntry a, LibraryEntry b) => b.openedAt.compareTo(a.openedAt));
    return out;
  }

  /// PDF를 악보함에 넣는다. 이미 있으면 기존 요약을 돌려준다.
  static Future<LibraryEntry> add(Uint8List bytes, String fileName) async {
    final Directory dir = await _dir();
    final String key = keyOf(bytes);
    final File meta = File('${dir.path}/$key.json');
    if (await meta.exists()) {
      final LibraryEntry e =
          LibraryEntry.fromJson(jsonDecode(await meta.readAsString()) as Map<String, dynamic>);
      return e;
    }
    await File('${dir.path}/$key.pdf').writeAsBytes(bytes);
    final String title = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '').trim();
    final LibraryEntry e = LibraryEntry(key: key, fileName: fileName, title: title, openedAt: DateTime.now());
    await save(e);
    return e;
  }

  static Future<Uint8List> bytesOf(String key) async {
    final Directory dir = await _dir();
    return File('${dir.path}/$key.pdf').readAsBytes();
  }

  static Future<ScoreAnalysisCache> analysisCache() async {
    final Directory dir = await _dir();
    return ScoreAnalysisCache(Directory('${dir.path}/analysis'));
  }

  static Future<void> save(LibraryEntry e) async {
    final Directory dir = await _dir();
    await File('${dir.path}/${e.key}.json').writeAsString(jsonEncode(e.toJson()));
  }

  /// 원곡 영상 썸네일(앱 폴더에 받아 둔 것). 없으면 null.
  static Future<File?> thumbnailOf(String key) async {
    final File f = File('${(await _dir()).path}/$key.jpg');
    return await f.exists() ? f : null;
  }

  /// 유튜브 썸네일을 받아 둔다. 합주실에 인터넷이 없어도 목록에 보이게 하려는 것이다.
  /// 실패해도 목록은 첫 글자로 보여 주면 되므로 조용히 넘어간다.
  static Future<File?> saveThumbnail(String key, String videoId) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse('https://i.ytimg.com/vi/$videoId/mqdefault.jpg'));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) return null;
      final BytesBuilder bytes = BytesBuilder();
      await for (final List<int> chunk in response) {
        bytes.add(chunk);
      }
      final File f = File('${(await _dir()).path}/$key.jpg');
      await f.writeAsBytes(bytes.takeBytes());
      return f;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static Future<void> removeThumbnail(String key) async {
    final File f = File('${(await _dir()).path}/$key.jpg');
    if (await f.exists()) await f.delete();
  }

  static Future<void> remove(String key) async {
    final Directory dir = await _dir();
    await (await analysisCache()).remove(key);
    for (final String ext in <String>['pdf', 'json', 'jpg']) {
      final File f = File('${dir.path}/$key.$ext');
      if (await f.exists()) await f.delete();
    }
  }
}
