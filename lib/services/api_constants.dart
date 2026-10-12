class ApiConstants {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'ws://localhost:8000',
  );

  /// 악보 한 장의 최대 크기. 서버의 MAX_SCORE_MB 와 같아야 한다.
  static const int maxScoreMb = 30;
  static const int maxScoreBytes = maxScoreMb * 1024 * 1024;
}
