/// 악보의 한 줄이 몇 마디에서 시작하는지 적어 둔 표시.
///
/// "3페이지 둘째 줄이 37마디" 를 그대로 옮긴 것이다. 연주자들이 원래
/// 쓰던 말이라 배울 것이 없다.
class ScoreAnchor {
  /// 몇 번째 페이지인가. 0 부터.
  final int page;

  /// 페이지 안에서의 세로 위치. 0.0 이 맨 위, 1.0 이 맨 아래.
  ///
  /// 픽셀이 아니라 비율이다. 태블릿과 폰의 화면이 다르고, 같은 기기에서도
  /// 확대 배율이 계속 바뀐다.
  final double y;

  /// 이 줄에서 실제 악보가 시작하고 끝나는 가로 위치.
  ///
  /// PDF의 흰 여백은 마디가 아니다. 이 범위를 알아야 줄의 첫 마디와
  /// 마지막 마디를 화면 끝이 아니라 실제 세로줄에 맞출 수 있다.
  final double xStart;
  final double xEnd;

  /// 이 줄의 첫 마디 번호.
  final double measure;

  /// 이 줄 다음에 오는 마디 번호. 마지막 줄도 정확히 계산하기 위해 둔다.
  /// null이면 다음 앵커의 시작 마디로 추론한다.
  final double? endMeasure;

  /// 이 악보 줄에서 검출한 실제 마디선의 페이지 기준 x 좌표.
  ///
  /// 1~5마디 줄이라면 `[왼쪽, 2마디 시작, 3마디 시작, 4마디 시작, 오른쪽]`
  /// 처럼 마디 수보다 하나 많은 좌표를 가진다. 검출하지 못했을 때는 비어 있으며,
  /// 그 경우에만 [xStart]와 [xEnd] 사이를 균등 분할한다.
  final List<double> barlines;

  /// 실제 오선 묶음의 아래쪽. 검출하지 못했으면 다음 줄의 y를 사용한다.
  final double? systemBottom;

  /// 이 시스템 안에서 도돌이표가 시작/끝나는 마디 경계 인덱스.
  /// 4마디 시스템의 경계는 0부터 4까지다.
  final List<int> repeatStarts;
  final List<int> repeatEnds;

  /// 1번·2번 엔딩이 시작되는 경계 인덱스. 2번 엔딩은 순서 검증과 표시용이고,
  /// 실제 건너뛰기 계산에는 1번 엔딩 시작점이 핵심이다.
  final List<int> firstEndings;
  final List<int> secondEndings;

  /// D.S.·D.C.·코다 같은 이동 기호. 키는 [segno]·[coda]·[toCoda]·[dalSegno]·
  /// [daCapo]·[fine], 값은 마디 경계 인덱스다. 세뇨와 코다는 그 경계에서
  /// 시작하는 마디에, 나머지는 그 경계에서 끝나는 마디에 붙는다.
  final Map<String, List<int>> navigation;

  static const String segno = 'segno';
  static const String coda = 'coda';
  static const String toCoda = 'to_coda';
  static const String dalSegno = 'ds';
  static const String daCapo = 'dc';
  static const String fine = 'fine';

  const ScoreAnchor({
    required this.page,
    required this.y,
    required this.measure,
    this.xStart = 0,
    this.xEnd = 1,
    this.endMeasure,
    this.barlines = const <double>[],
    this.systemBottom,
    this.repeatStarts = const <int>[],
    this.repeatEnds = const <int>[],
    this.firstEndings = const <int>[],
    this.secondEndings = const <int>[],
    this.navigation = const <String, List<int>>{},
  });

  factory ScoreAnchor.fromJson(Map<String, dynamic> json) => ScoreAnchor(
        page: (json['page'] as num).toInt(),
        y: (json['y'] as num).toDouble(),
        measure: (json['measure'] as num).toDouble(),
        xStart: (json['x_start'] as num?)?.toDouble() ?? 0,
        xEnd: (json['x_end'] as num?)?.toDouble() ?? 1,
        endMeasure: (json['end_measure'] as num?)?.toDouble(),
        barlines: (json['barlines'] as List<dynamic>?)
                ?.map((dynamic value) => (value as num).toDouble())
                .toList() ??
            const <double>[],
        systemBottom: (json['system_bottom'] as num?)?.toDouble(),
        repeatStarts: _intList(json['repeat_starts']),
        repeatEnds: _intList(json['repeat_ends']),
        firstEndings: _intList(json['first_endings']),
        secondEndings: _intList(json['second_endings']),
        navigation: json['navigation'] is Map<String, dynamic>
            ? (json['navigation'] as Map<String, dynamic>).map(
                (String key, dynamic value) => MapEntry(key, _intList(value)))
            : const <String, List<int>>{},
      );

  static List<int> _intList(dynamic value) => value is List<dynamic>
      ? value.map((dynamic item) => (item as num).toInt()).toList()
      : const <int>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page': page,
        'y': y,
        'measure': measure,
        'x_start': xStart,
        'x_end': xEnd,
        if (endMeasure != null) 'end_measure': endMeasure,
        if (barlines.isNotEmpty) 'barlines': barlines,
        if (systemBottom != null) 'system_bottom': systemBottom,
        if (repeatStarts.isNotEmpty) 'repeat_starts': repeatStarts,
        if (repeatEnds.isNotEmpty) 'repeat_ends': repeatEnds,
        if (firstEndings.isNotEmpty) 'first_endings': firstEndings,
        if (secondEndings.isNotEmpty) 'second_endings': secondEndings,
        if (navigation.isNotEmpty) 'navigation': navigation,
      };

  ScoreAnchor copyWith({
    int? page,
    double? y,
    double? measure,
    double? xStart,
    double? xEnd,
    double? endMeasure,
    List<double>? barlines,
    double? systemBottom,
    List<int>? repeatStarts,
    List<int>? repeatEnds,
    List<int>? firstEndings,
    List<int>? secondEndings,
    Map<String, List<int>>? navigation,
  }) =>
      ScoreAnchor(
        page: page ?? this.page,
        y: y ?? this.y,
        measure: measure ?? this.measure,
        xStart: xStart ?? this.xStart,
        xEnd: xEnd ?? this.xEnd,
        endMeasure: endMeasure ?? this.endMeasure,
        barlines: barlines ?? this.barlines,
        systemBottom: systemBottom ?? this.systemBottom,
        repeatStarts: repeatStarts ?? this.repeatStarts,
        repeatEnds: repeatEnds ?? this.repeatEnds,
        firstEndings: firstEndings ?? this.firstEndings,
        secondEndings: secondEndings ?? this.secondEndings,
        navigation: navigation ?? this.navigation,
      );

  @override
  String toString() =>
      'ScoreAnchor(p$page, y=$y, x=$xStart~$xEnd, m=$measure~$endMeasure, '
      'barlines=${barlines.length}, repeats=$repeatStarts/$repeatEnds)';
}

/// 어떤 마디가 악보의 어디에 있는지.
class MeasureBand {
  final int page;

  /// 이 줄의 위아래. 둘 다 0.0~1.0.
  final double top;
  final double bottom;

  /// 줄 안에서의 가로 위치. 0.0 이 줄의 시작, 1.0 이 끝.
  final double x;

  /// 선택한 마디 하나의 실제 가로 범위. 둘 다 페이지 기준 0.0~1.0.
  final double left;
  final double right;

  /// 이 줄이 담고 있는 마디 범위.
  final double startMeasure;
  final double endMeasure;

  const MeasureBand({
    required this.page,
    required this.top,
    required this.bottom,
    required this.x,
    required this.left,
    required this.right,
    required this.startMeasure,
    required this.endMeasure,
  });

  @override
  String toString() =>
      'MeasureBand(p$page, $top~$bottom, x=$x, bar=$left~$right, '
      'm$startMeasure~$endMeasure)';
}
