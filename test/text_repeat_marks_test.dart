import 'package:barlink/services/score_layout_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 가로 400px, 세로 200px 페이지에 오선 하나(줄 간격 10px, 100~140).
  // 마디선은 0·100·200·300·400.
  const int w = 400, h = 200;
  const List<int> rows = <int>[100, 110, 120, 130, 140];
  const List<double> bounds = <double>[0, 100, 200, 300, 400];
  List<double> dot(double x, double pos, {double size = 1.5}) =>
      <double>[x / w, (100 + pos * 10) / h, size / w, size / h];

  test('가운데 줄을 사이에 둔 2·3번째 칸 점 짝을 도돌이로 읽고 방향을 가른다', () {
    final (List<int> starts, List<int> ends) = textRepeatMarksForTesting(
      <List<double>>[
        dot(106, 1.45), dot(106, 2.45), // 100 마디선 바로 오른쪽 = 시작
        dot(292, 1.45), dot(292, 2.45), // 300 마디선 바로 왼쪽 = 끝
      ],
      w,
      h,
      rows,
      10,
      bounds,
    );
    expect(starts, <int>[1]);
    expect(ends, <int>[3]);
  });

  test('화음 점음표처럼 아래 칸까지 점이 이어지면 도돌이가 아니다', () {
    final (List<int> starts, List<int> ends) = textRepeatMarksForTesting(
      <List<double>>[dot(150, 1.5), dot(150, 2.5), dot(150, 3.5)],
      w,
      h,
      rows,
      10,
      bounds,
    );
    expect(starts, isEmpty);
    expect(ends, isEmpty);
  });

  test('위쪽 점의 글자 상자가 위나 아래로 길게 잡혀도 도돌이로 읽는다', () {
    // 실제 점은 1.45칸. 상자 높이가 3.5칸이라 중심이 엉뚱한 곳에 온다.
    List<double> tall(double x, double center) =>
        <double>[x / w, (100 + center * 10) / h, 1.5 / w, 35 / h];
    final (List<int> starts, List<int> ends) = textRepeatMarksForTesting(
      <List<double>>[
        tall(106, -0.1), dot(106, 2.45), // 먹이사슬: 아래 끝이 맞다
        tall(292, 3.0), dot(292, 2.45), // 좋은 밤 좋은 꿈: 위 끝이 맞다
      ],
      w,
      h,
      rows,
      10,
      bounds,
    );
    expect(starts, <int>[1]);
    expect(ends, <int>[3]);
  });

  test('선 데이터가 있으면 굵은 세로선 옆 점만 도돌이로, 방향은 굵은 선 기준으로 읽는다', () {
    final (List<int> starts, List<int> ends) = textRepeatMarksForTesting(
      <List<double>>[
        dot(106, 1.45), dot(106, 2.45), // 100의 굵은 선 오른쪽 = 시작
        dot(292, 1.45), dot(292, 2.45), // 298의 굵은 선 왼쪽 = 끝
        dot(150, 1.45), dot(150, 2.45), // 굵은 선 없음 = 도돌이 아님
      ],
      w,
      h,
      rows,
      10,
      bounds,
      thick: <double>[101, 298],
    );
    expect(starts, <int>[1]);
    expect(ends, <int>[3]);
  });

  test('짝이 없는 점 하나(점음표)는 도돌이가 아니다', () {
    final (List<int> starts, List<int> ends) = textRepeatMarksForTesting(
      <List<double>>[dot(250, 2.5)],
      w,
      h,
      rows,
      10,
      bounds,
    );
    expect(starts, isEmpty);
    expect(ends, isEmpty);
  });
}
