import 'dart:io';
import 'dart:typed_data';

import 'package:barlink/services/original_reference_store.dart';
import 'package:barlink/services/reference_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory originals;
  late OriginalReferenceStore store;
  const path = <int>[1, 2];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('original-reference-test-');
    originals = await Directory('${root.path}/originals').create();
    store = OriginalReferenceStore(originals);
  });

  tearDown(() async => root.delete(recursive: true));

  Future<File> audio([String name = 'download.m4a']) async =>
      File('${originals.path}/$name').writeAsString('test audio');

  Future<void> decode(String audio, String pcm) async {
    expect(await File(audio).exists(), isTrue);
    await File(pcm).writeAsBytes(<int>[0, 0, 1, 0]);
  }

  Future<ReferenceTrack> analyze(String pcm) async {
    expect(await File(pcm).exists(), isTrue);
    return _reference();
  }

  test('특징 저장 성공 후 다운로드 음원·PCM을 지워도 다시 로드할 수 있다', () async {
    final input = await audio();
    await store.build(
      key: 'score',
      audioFile: input.path,
      label: '원곡',
      path: path,
      downloaded: true,
      decode: decode,
      analyze: analyze,
    );
    expect(await input.exists(), isFalse);
    expect(await File('${originals.path}/decode_score.pcm').exists(), isFalse);
    expect(await File('${originals.path}/score.bin').exists(), isTrue);
    expect(await File('${originals.path}/score.json').exists(), isTrue);
    final loaded = await OriginalReferenceStore(originals).load('score', path);
    expect(loaded, isNotNull);
    expect(loaded!.$2, '원곡');
    expect(loaded.$1.templates, _reference().templates);
    expect(loaded.$1.measureTimes, <double>[0, 2, 4]);
    expect(await store.previousAudio('score'), isNull);
  });

  test('사용자가 고른 음원은 저장·로드 후에도 보존한다', () async {
    final input = await audio('user-selected.mp3');
    await store.build(
      key: 'score',
      audioFile: input.path,
      label: '사용자 파일',
      path: path,
      decode: decode,
      analyze: analyze,
    );
    expect(await store.load('score', path), isNotNull);
    expect(await input.exists(), isTrue);
    expect(await store.previousAudio('score'), (input.path, '사용자 파일', false));
  });

  test('다운로드로 표시되어도 앱 음원 폴더 밖 파일은 지우지 않는다', () async {
    final input =
        await File('${root.path}/outside.m4a').writeAsString('user audio');
    await store.build(
      key: 'score',
      audioFile: input.path,
      label: '외부 파일',
      path: path,
      downloaded: true,
      decode: decode,
      analyze: analyze,
    );
    expect(await store.load('score', path), isNotNull);
    expect(await input.exists(), isTrue);
  });

  test('디코딩 중 실패하면 부분 PCM을 정리하고 음원은 남긴다', () async {
    final input = await audio();
    await expectLater(
        store.build(
          key: 'score',
          audioFile: input.path,
          label: '원곡',
          path: path,
          downloaded: true,
          decode: (audio, pcm) async {
            await File(pcm).writeAsString('partial');
            throw StateError('decode failed');
          },
          analyze: analyze,
        ),
        throwsStateError);
    expect(await input.exists(), isTrue);
    expect(await File('${originals.path}/decode_score.pcm').exists(), isFalse);
    expect(await File('${originals.path}/score.json').exists(), isFalse);
  });

  test('분석 중 실패하면 PCM을 정리하고 음원은 남긴다', () async {
    final input = await audio();
    await expectLater(
        store.build(
          key: 'score',
          audioFile: input.path,
          label: '원곡',
          path: path,
          downloaded: true,
          decode: decode,
          analyze: (pcm) async => throw StateError('analysis failed'),
        ),
        throwsStateError);
    expect(await input.exists(), isTrue);
    expect(await File('${originals.path}/decode_score.pcm').exists(), isFalse);
  });

  test('메타데이터 저장 실패 시 음원을 삭제하지 않는다', () async {
    final input = await audio();
    await Directory('${originals.path}/score.json').create();
    await expectLater(
        store.build(
          key: 'score',
          audioFile: input.path,
          label: '원곡',
          path: path,
          downloaded: true,
          decode: decode,
          analyze: analyze,
        ),
        throwsA(isA<FileSystemException>()));
    expect(await input.exists(), isTrue);
    expect(await File('${originals.path}/decode_score.pcm').exists(), isFalse);
  });

  test('유효하지 않은 분석 결과는 저장하거나 음원을 삭제하지 않는다', () async {
    final input = await audio();
    await expectLater(
        store.build(
          key: 'score',
          audioFile: input.path,
          label: '원곡',
          path: path,
          downloaded: true,
          decode: decode,
          analyze: (pcm) async => const ReferenceTrack(
            res: 4,
            templates: <Float64List>[],
            measureTimes: <double>[],
            keyShift: 0,
            fit: 0,
          ),
        ),
        throwsStateError);
    expect(await input.exists(), isTrue);
    expect(await File('${originals.path}/score.bin').exists(), isFalse);
  });

  test('이전 버전이 남긴 다운로드도 유효한 특징 로드 후 정리한다', () async {
    final input = await audio();
    await File('${originals.path}/score.bin')
        .writeAsBytes(_reference().encodeTemplates());
    await File('${originals.path}/score.json')
        .writeAsString(_reference().encodeMeta(
      <String, dynamic>{
        'path': OriginalReferenceStore.signature(path),
        'audio': input.path,
        'label': '이전 원곡'
      },
    ));
    expect(await store.load('score', path), isNotNull);
    expect(await input.exists(), isFalse);
  });

  test('반복 순서 불일치 또는 특징 손상 시 남아 있는 음원을 보존한다', () async {
    final input = await audio();
    await File('${originals.path}/score.bin')
        .writeAsBytes(_reference().encodeTemplates());
    await File('${originals.path}/score.json')
        .writeAsString(_reference().encodeMeta(
      <String, dynamic>{
        'path': OriginalReferenceStore.signature(path),
        'audio': input.path
      },
    ));
    expect(await store.load('score', <int>[1, 2, 1]), isNull);
    expect(await input.exists(), isTrue);
    expect(await store.previousAudio('score'), (input.path, '원곡', true));
    await File('${originals.path}/score.bin').writeAsBytes(<int>[0, 0, 0, 0]);
    expect(await store.load('score', path), isNull);
    expect(await input.exists(), isTrue);
  });

  test('메타데이터가 특징 파일을 음원으로 가리켜도 삭제하지 않는다', () async {
    final file = File('${originals.path}/score.json');
    await File('${originals.path}/score.bin')
        .writeAsBytes(_reference().encodeTemplates());
    await file.writeAsString(_reference().encodeMeta(<String, dynamic>{
      'path': OriginalReferenceStore.signature(path),
      'audio': file.path,
      'audio_owned': true,
    }));
    expect(await store.load('score', path), isNotNull);
    expect(await file.exists(), isTrue);
  });
}

ReferenceTrack _reference() => ReferenceTrack(
      res: 4,
      templates: List<Float64List>.generate(
          32,
          (_) => Float64List.fromList(
              <double>[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])),
      measureTimes: <double>[0, 2, 4],
      keyShift: 0,
      fit: 1,
    );
