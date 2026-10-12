import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'chord_chart.dart';
import 'original_audio.dart';
import 'original_reference_store.dart';
import 'reference_track.dart';

/// 악보 하나에 맞춰 둔 원곡 기준을 찾고, 만들고, 저장한다.
class OriginalReference {
  static Future<Directory> _dir() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory('${base.path}/originals').create(recursive: true);
  }

  static Future<String> folder() async => (await _dir()).path;

  /// 연주 순서가 바뀌면(도돌이 인식이 달라지면) 저장본을 쓸 수 없다.
  static String signature(List<int> path) =>
      OriginalReferenceStore.signature(path);

  /// 저장해 둔 원곡 기준. 없거나 연주 순서가 다르면 null.
  static Future<(ReferenceTrack, String?)?> load(String key, List<int> path,
      {Map<int, double> tempoChanges = const <int, double>{}}) async {
    try {
      return await OriginalReferenceStore(await _dir())
          .load(key, path, tempoChanges: tempoChanges);
    } catch (_) {
      return null;
    }
  }

  /// 음원 파일을 풀고 악보에 맞춘 뒤 저장한다. 수 초 걸린다.
  static Future<ReferenceTrack> build({
    required String key,
    required String audioFile,
    required String label,
    required ChordChart chart,
    required List<int> path,
    required double bpm,
    bool downloaded = false,
  }) async {
    return OriginalReferenceStore(await _dir()).build(
      key: key,
      audioFile: audioFile,
      label: label,
      path: path,
      downloaded: downloaded,
      tempoChanges: chart.tempoChanges,
      decode: OriginalAudio.decodeToFile,
      analyze: (pcm) => compute(_buildIsolate, (pcm, chart, path, bpm)),
    );
  }

  /// 예전에 유튜브에서 받아 맞춘 원곡의 영상 ID(썸네일용). 없으면 null.
  static Future<String?> recordedVideoId(String key) async {
    try {
      return await OriginalReferenceStore(await _dir()).recordedVideoId(key);
    } catch (_) {
      return null;
    }
  }

  /// 예전에 맞춰 둔 원곡 파일. 도돌이 인식이 바뀌어 연주 순서가 달라졌을 때
  /// 이 파일로 다시 맞춘다. 파일이 없으면 null.
  static Future<(String, String, bool)?> previousAudio(String key) async {
    try {
      return await OriginalReferenceStore(await _dir()).previousAudio(key);
    } catch (_) {
      return null;
    }
  }
}

/// 별도 isolate에서 원곡 PCM을 읽고 악보에 맞춘다(최상위 함수여야 넘길 수 있다).
ReferenceTrack _buildIsolate((String, ChordChart, List<int>, double) args) {
  final (String pcm, ChordChart chart, List<int> path, double bpm) = args;
  return ReferenceTrack.build(OriginalAudio.readPcm(pcm), chart, path, bpm);
}
