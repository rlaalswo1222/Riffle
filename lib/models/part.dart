/// 합주에서 맡는 자리.
///
/// 서버의 config.PARTS 와 같은 목록이어야 한다. 한쪽만 늘리면 고른
/// 파트가 400 으로 되돌아온다.
class Part {
  final String id;
  final String label;

  const Part(this.id, this.label);

  static const List<Part> all = <Part>[
    Part('vocal', '보컬'),
    Part('guitar', '기타'),
    Part('bass', '베이스'),
    Part('drum', '드럼'),
    Part('keyboard', '건반'),
    Part('other', '그 외'),
  ];

  static String labelOf(String? id) {
    for (final Part p in all) {
      if (p.id == id) return p.label;
    }
    return '악보';
  }
}
