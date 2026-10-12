/// 방에 올라와 있는 악보 한 장.
class ScoreInfo {
  final String scoreId;
  final String? part;
  final String fileUrl;
  final String fileType;
  final String uploadedBy;

  /// 이 악보에 찍힌 앵커 수.
  ///
  /// 0 이면 아직 아무 데도 이어지지 않은 악보다. 목록에서 바로
  /// 보여줘야 "왜 내 화면만 안 움직이지" 를 겪지 않는다.
  final int anchorCount;

  const ScoreInfo({
    required this.scoreId,
    required this.part,
    required this.fileUrl,
    required this.fileType,
    required this.uploadedBy,
    required this.anchorCount,
  });

  bool get isPdf => fileType == 'pdf';
  bool get isLinked => anchorCount > 0;

  factory ScoreInfo.fromJson(Map<String, dynamic> json) => ScoreInfo(
        scoreId: json['score_id'] as String,
        part: json['part'] as String?,
        fileUrl: json['file_url'] as String,
        fileType: json['file_type'] as String? ?? 'pdf',
        uploadedBy: json['uploaded_by'] as String? ?? '',
        anchorCount: (json['anchor_count'] as num?)?.toInt() ?? 0,
      );
}
