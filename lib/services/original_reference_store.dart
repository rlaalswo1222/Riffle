import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'chord_chart.dart';
import 'reference_track.dart';

/// 원곡 특징 저장과 입력 파일 수명 관리. 앱이 받은 음원만 성공 후 정리한다.
class OriginalReferenceStore {
  final Directory directory;

  const OriginalReferenceStore(this.directory);

  /// 연주 순서(와 곡 중간 템포 변화)가 같아야 저장한 특징을 쓸 수 있다.
  /// 템포 변화가 없는 곡은 예전과 같은 값이라 기존 저장본이 그대로 유효하다.
  static String signature(List<int> path,
      [Map<int, double> tempoChanges = const <int, double>{}]) {
    final List<int> marks = tempoChanges.keys.toList()..sort();
    final String tempo = marks.isEmpty
        ? ''
        : '|tempo:${marks.map((int m) => '$m=${tempoChanges[m]}').join(',')}';
    return sha256.convert(utf8.encode('${path.join(',')}$tempo')).toString();
  }

  File _meta(String key) => File('${directory.path}/$key.json');
  File _bin(String key) => File('${directory.path}/$key.bin');

  Future<(ReferenceTrack, String?)?> load(String key, List<int> path,
      {Map<int, double> tempoChanges = const <int, double>{}}) async {
    try {
      final text = await _meta(key).readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['path'] != signature(path, tempoChanges)) return null;
      final label = json['label'] as String?;
      final ref = ReferenceTrack.decode(await _bin(key).readAsBytes(), text);
      if (!_isValid(ref, path)) return null;
      // 이전 버전이 남겨 둔 다운로드 파일도 유효한 특징을 읽은 뒤 정리한다.
      final audio = json['audio'] as String?;
      if (audio != null && json['audio_owned'] != false) {
        await _removeDownloadedAudio(audio);
      }
      return (ref, label);
    } catch (_) {
      return null;
    }
  }

  Future<ReferenceTrack> build({
    required String key,
    required String audioFile,
    required String label,
    required List<int> path,
    required Future<void> Function(String audio, String pcm) decode,
    required Future<ReferenceTrack> Function(String pcm) analyze,
    bool downloaded = false,
    Map<int, double> tempoChanges = const <int, double>{},
  }) async {
    await directory.create(recursive: true);
    final pcm = File('${directory.path}/decode_$key.pcm');
    try {
      await decode(audioFile, pcm.path);
      final ref = await analyze(pcm.path);
      if (!_isValid(ref, path)) throw StateError('원곡 분석 결과를 저장할 수 없습니다.');
      // 특징과 메타데이터를 모두 기록한 뒤에만 다운로드 음원을 지운다.
      await _bin(key).writeAsBytes(ref.encodeTemplates(), flush: true);
      await _meta(key).writeAsString(
          ref.encodeMeta(<String, dynamic>{
            'path': signature(path, tempoChanges),
            'label': label,
            'audio': audioFile,
            'audio_owned': downloaded,
          }),
          flush: true);
      if (downloaded) await _removeDownloadedAudio(audioFile);
      return ref;
    } finally {
      await _removeIfPresent(pcm);
    }
  }

  Future<(String, String, bool)?> previousAudio(String key) async {
    try {
      final json =
          jsonDecode(await _meta(key).readAsString()) as Map<String, dynamic>;
      final audio = json['audio'] as String?;
      if (audio == null || !await File(audio).exists()) return null;
      final downloaded =
          json['audio_owned'] != false && await _isDownloadedAudio(audio);
      return (audio, json['label'] as String? ?? '원곡', downloaded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _removeDownloadedAudio(String path) async {
    try {
      if (await _isDownloadedAudio(path)) await File(path).delete();
    } on FileSystemException {
      // 특징은 이미 저장되어 있다. 삭제 실패는 다음 로드에서 재시도한다.
    }
  }

  bool _isValid(ReferenceTrack ref, List<int> path) =>
      path.isNotEmpty &&
      ref.res > 0 &&
      ref.templates.length ==
          path.length * ChordChart.beatsPerMeasure * ref.res &&
      ref.measureTimes.length == path.length + 1 &&
      ref.fit.isFinite &&
      ref.templates.every((template) =>
          template.length == 12 && template.every((value) => value.isFinite)) &&
      ref.measureTimes.every((time) => time.isFinite);

  Future<bool> _isDownloadedAudio(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final resolved = File(await file.resolveSymbolicLinks());
    final root = await directory.resolveSymbolicLinks();
    final parent = await resolved.parent.resolveSymbolicLinks();
    String comparable(String path) =>
        Platform.isWindows ? path.toLowerCase() : path;
    if (comparable(parent) != comparable(root)) return false;
    // 특징·JSON·임시 파일은 메타데이터에 잘못 기록되어도 삭제하지 않는다.
    const audioExtensions = <String>[
      '.m4a',
      '.mp3',
      '.mp4',
      '.webm',
      '.opus',
      '.ogg',
      '.aac',
      '.wav',
      '.flac',
    ];
    return audioExtensions.any(resolved.path.toLowerCase().endsWith);
  }

  Future<void> _removeIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 임시 파일 정리 실패가 원래 분석 결과나 오류를 가리지 않게 한다.
    }
  }
}
