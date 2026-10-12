import 'package:shared_preferences/shared_preferences.dart';

/// 추종 고급 설정. 대부분 손댈 일이 없어서 고급 메뉴에만 둔다.
class FollowSettings {
  /// 배경 소음과 연주 음량 사이 어디를 '연주 있음' 기준으로 볼지(0~1).
  double split;

  /// 표시 위치를 앞당기는 시간(초). 마이크·스피커 지연을 메운다.
  double leadSeconds;

  /// 페이지를 미리 넘기는 박 수.
  double turnBeats;

  /// 원곡이 있으면 원곡 기준으로 따라갈지.
  bool useReference;

  FollowSettings({
    this.split = 0.35,
    this.leadSeconds = 0.3,
    this.turnBeats = 2,
    this.useReference = true,
  });

  static Future<FollowSettings> load() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return FollowSettings(
        split: p.getDouble('follow.split') ?? 0.35,
        leadSeconds: p.getDouble('follow.lead') ?? 0.3,
        turnBeats: p.getDouble('follow.turn') ?? 2,
        useReference: p.getBool('follow.reference') ?? true,
      );
    } catch (_) {
      return FollowSettings();
    }
  }

  Future<void> save() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setDouble('follow.split', split);
      await p.setDouble('follow.lead', leadSeconds);
      await p.setDouble('follow.turn', turnBeats);
      await p.setBool('follow.reference', useReference);
    } catch (_) {
      // 저장이 안 돼도 이번 연주에는 쓴다.
    }
  }
}
