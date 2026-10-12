import 'package:barlink/models/score_anchor.dart';
import 'package:barlink/services/score_layout_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;

void main() {
  test('실제 간격이 다른 마디선을 이미지에서 찾는다', () {
    final image_lib.Image page = image_lib.Image(width: 600, height: 400);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));

    const List<int> staffRows = <int>[100, 108, 116, 124, 132];
    const List<int> barlines = <int>[60, 170, 300, 410, 540];
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in staffRows) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    for (final int x in barlines) {
      image_lib.drawLine(page, x1: x, y1: 100, x2: x, y2: 132, color: black);
    }
    // 마디선이 아닌 음표 기둥 후보도 섞는다.
    for (final int x in <int>[118, 235, 365, 475]) {
      image_lib.drawLine(page, x1: x, y1: 82, x2: x, y2: 125, color: black);
    }

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'page': 0,
            'bytes': image_lib.encodePng(page),
          },
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(
            page: 0,
            y: 0.22,
            measure: 1,
            endMeasure: 5,
          ).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.single);
    expect(detected.barlines, hasLength(5));
    for (int index = 0; index < barlines.length; index++) {
      expect(detected.barlines[index], closeTo(barlines[index] / 600, 0.012));
    }
    expect(detected.systemBottom, isNotNull);
  });

  test('마지막 줄의 실제 마디 수가 추정값보다 하나 적으면 바로잡는다', () {
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    for (final int x in <int>[60, 220, 380, 540]) {
      image_lib.drawLine(page, x1: x, y1: 90, x2: x, y2: 122, color: black);
    }

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{'page': 0, 'bytes': image_lib.encodePng(page)},
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(
            page: 0,
            y: 0.27,
            measure: 70,
            endMeasure: 74,
          ).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.single);
    expect(detected.endMeasure, 73);
    expect(detected.barlines, hasLength(4));
  });

  test('첫 줄의 짐작 위치가 오선 안쪽이면 박스 윗선을 오선 위로 옮긴다', () {
    // 첫 줄은 마디 번호가 인쇄되지 않아 y를 짐작한다(있잖아 첫 줄: 오선 중간).
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    for (final int x in <int>[60, 180, 300, 420, 540]) {
      image_lib.drawLine(page, x1: x, y1: 90, x2: x, y2: 122, color: black);
    }

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{'page': 0, 'bytes': image_lib.encodePng(page)},
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(page: 0, y: 0.35, measure: 1, endMeasure: 5).toJson(),
          const ScoreAnchor(page: 0, y: 0.8, measure: 5).toJson(),
        ],
      },
    );

    final ScoreAnchor first = ScoreAnchor.fromJson(result.first);
    expect(first.y, lessThan(90 / 300));
    expect(first.y, greaterThan(70 / 300));
  });

  test('PDF 선 데이터가 있으면 양 끝이 오선 줄에 맞는 선만 마디선으로 쓴다', () {
    // 그림에는 오선만 있다. 마디선과 음표 기둥은 선 데이터로만 준다.
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    List<double> line(double x, double top, double bottom) =>
        <double>[x / 600, top / 300, bottom / 300, 0.66 / 595];

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'page': 0,
            'bytes': image_lib.encodePng(page),
            'lines': <List<double>>[
              for (final double x in <double>[240, 340, 440, 540]) line(x, 90, 122),
              line(150, 92, 120), // 음표 기둥: 오선 줄과 끝이 안 맞는다
              line(300, 90, 118), // 위끝만 맞는 기둥
              line(400, 60, 80), // 1·2번 괄호 갈고리: 오선 밖
            ],
          },
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(page: 0, y: 0.27, measure: 10, endMeasure: 14).toJson(),
          const ScoreAnchor(page: 0, y: 0.8, measure: 14).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.first);
    expect(detected.barlines, hasLength(5));
    for (final (int i, double x) in <(int, double)>[(1, 240), (2, 340), (3, 440), (4, 540)]) {
      expect(detected.barlines[i], closeTo(x / 600, 0.005));
    }
  });

  test('첫 마디가 넓어도, 오선 밖으로 뻗은 음표 기둥이 있어도 진짜 마디선을 고른다', () {
    // 있잖아(샵 6개) 한 보표 줄: 조표 때문에 첫 마디가 넓고, 빔에 이어진
    // 기둥이 오선 전체를 덮은 채 위로 뻗어 있다.
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    for (final int x in <int>[60, 250, 360, 450, 540]) {
      image_lib.drawLine(page, x1: x, y1: 90, x2: x, y2: 122, color: black);
    }
    image_lib.drawLine(page, x1: 150, y1: 84, x2: 150, y2: 122, color: black);

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{'page': 0, 'bytes': image_lib.encodePng(page)},
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(page: 0, y: 0.27, measure: 10, endMeasure: 14).toJson(),
          const ScoreAnchor(page: 0, y: 0.8, measure: 14).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.first);
    expect(detected.barlines, hasLength(5));
    expect(detected.barlines[1], closeTo(250 / 600, 0.01));
  });

  test('마지막 줄의 실제 마디 수가 추정값보다 많아도 마디선을 세어 바로잡는다', () {
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    // 마지막 마디가 좁은 5마디 줄(예감 좋은 날, 시간을 달리네의 끝 줄).
    for (final int x in <int>[60, 170, 280, 390, 470, 540]) {
      image_lib.drawLine(page, x1: x, y1: 90, x2: x, y2: 122, color: black);
    }

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{'page': 0, 'bytes': image_lib.encodePng(page)},
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(
            page: 0,
            y: 0.27,
            measure: 75,
            endMeasure: 79,
          ).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.single);
    expect(detected.endMeasure, 80);
    expect(detected.barlines, hasLength(6));
  });

  test('마디선 양쪽의 두 점으로 도돌이표 방향을 구분한다', () {
    final image_lib.Image page = image_lib.Image(width: 600, height: 300);
    image_lib.fill(page, color: image_lib.ColorRgb8(255, 255, 255));
    final image_lib.Color black = image_lib.ColorRgb8(0, 0, 0);
    for (final int y in <int>[90, 98, 106, 114, 122]) {
      image_lib.drawLine(page, x1: 60, y1: y, x2: 540, y2: y, color: black);
    }
    for (final int x in <int>[60, 180, 300, 420, 540]) {
      image_lib.drawLine(page, x1: x, y1: 90, x2: x, y2: 122, color: black);
    }
    image_lib.fillRect(
      page,
      x1: 94,
      y1: 90,
      x2: 101,
      y2: 122,
      color: black,
    );
    image_lib.fillRect(
      page,
      x1: 529,
      y1: 90,
      x2: 536,
      y2: 122,
      color: black,
    );
    for (final int y in <int>[102, 110]) {
      image_lib.fillCircle(page, x: 108, y: y, radius: 2, color: black);
      image_lib.fillCircle(page, x: 523, y: y, radius: 2, color: black);
    }
    // 반복점 가까이에 있는 가느다란 음표 기둥은 반복점으로 보면 안 된다.
    image_lib.drawLine(
      page,
      x1: 189,
      y1: 88,
      x2: 189,
      y2: 116,
      color: black,
    );

    final List<Map<String, Object?>> result = detectScoreLayoutForTesting(
      <String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{'page': 0, 'bytes': image_lib.encodePng(page)},
        ],
        'anchors': <Map<String, dynamic>>[
          const ScoreAnchor(
            page: 0,
            y: 0.27,
            measure: 1,
            endMeasure: 5,
          ).toJson(),
        ],
      },
    );

    final ScoreAnchor detected = ScoreAnchor.fromJson(result.single);
    expect(detected.repeatStarts, <int>[0]);
    expect(detected.repeatEnds, <int>[4]);
  });
}
