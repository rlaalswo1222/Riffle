import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/measure_map.dart';
import '../models/score_anchor.dart';

/// 실시간 추종 화면에서 지금 위치를 어떻게 보여 줄지.
enum FollowLook {
  /// 예전 위치 공유 화면의 표시(채운 막대 + 주황 진행선).
  classic,

  /// 시작 마디: 점선 테두리와 '시작' 표시.
  start,

  /// 소리로 확인하기 전: 줄 배경 + 점선 테두리.
  provisional,

  /// 따라가는 중: 줄 배경 + 실선 테두리 + 진행선.
  tracking,
}

/// 악보 한 페이지와 마디 위치 오버레이.
///
/// 오버레이와 탭 좌표는 흰 여백을 포함한 PDF 페이지 자체를 기준으로 한다.
/// 선택 위치가 바뀌어도 현재 확대 배율과 화면 위치는 유지한다.
class ScorePageView extends StatefulWidget {
  final Uint8List? image;
  final MeasureMap map;
  final int page;
  final double aspectRatio;
  final MeasureBand? highlight;
  final bool editing;
  final void Function(double x, double y)? onTapPosition;
  final void Function(ScoreAnchor anchor)? onTapAnchor;

  /// 지금 위치를 그리는 방식.
  final FollowLook look;

  /// 다음 줄의 첫 마디. 있으면 '다음' 표시를 붙인다.
  final MeasureBand? nextLine;

  /// 확대·이동을 허용할지. 연주 화면에서는 끈다(밀어서 페이지를 넘기므로).
  final bool zoomable;

  const ScorePageView({
    super.key,
    required this.image,
    required this.map,
    required this.page,
    this.aspectRatio = 1 / 1.41421356237,
    this.highlight,
    this.editing = false,
    this.onTapPosition,
    this.onTapAnchor,
    this.look = FollowLook.classic,
    this.nextLine,
    this.zoomable = true,
  });

  @override
  State<ScorePageView> createState() => _ScorePageViewState();
}

class _ScorePageViewState extends State<ScorePageView> {
  static const double _grabY = 0.02;

  final TransformationController _transformation = TransformationController();

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return InteractiveViewer(
          transformationController: _transformation,
          minScale: 1,
          maxScale: widget.zoomable ? 5 : 1,
          panEnabled: widget.zoomable,
          scaleEnabled: widget.zoomable,
          child: Center(
            child: AspectRatio(
              aspectRatio: widget.aspectRatio,
              child: LayoutBuilder(
                builder:
                    (BuildContext context, BoxConstraints pageConstraints) {
                  return GestureDetector(
                    onTapUp: (TapUpDetails details) =>
                        _handleTap(details, pageConstraints),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        Image.memory(widget.image!, fit: BoxFit.fill),
                        CustomPaint(
                          painter: widget.look == FollowLook.classic
                              ? _OverlayPainter(
                                  anchors: widget.map.onPage(widget.page),
                                  highlight: widget.highlight?.page == widget.page
                                      ? widget.highlight
                                      : null,
                                  editing: widget.editing,
                                )
                              : _FollowPainter(
                                  band: widget.highlight?.page == widget.page
                                      ? widget.highlight
                                      : null,
                                  next: widget.nextLine?.page == widget.page
                                      ? widget.nextLine
                                      : null,
                                  look: widget.look,
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTap(TapUpDetails details, BoxConstraints constraints) {
    final double x =
        (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final double y =
        (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    if (widget.editing && widget.onTapAnchor != null) {
      for (final ScoreAnchor anchor in widget.map.onPage(widget.page)) {
        if ((anchor.y - y).abs() <= _grabY) {
          widget.onTapAnchor!(anchor);
          return;
        }
      }
    }
    widget.onTapPosition?.call(x, y);
  }
}

class _OverlayPainter extends CustomPainter {
  final List<ScoreAnchor> anchors;
  final MeasureBand? highlight;
  final bool editing;

  _OverlayPainter({
    required this.anchors,
    required this.highlight,
    required this.editing,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final MeasureBand? band = highlight;
    if (band != null) {
      final Rect row = Rect.fromLTRB(
        0,
        band.top * size.height,
        size.width,
        band.bottom * size.height,
      );
      final Rect bar = Rect.fromLTRB(
        band.left * size.width,
        row.top,
        band.right * size.width,
        row.bottom,
      );

      canvas.drawRect(row, Paint()..color = const Color(0x142F6BFF));
      canvas.drawRect(bar, Paint()..color = const Color(0x332F6BFF));
      canvas.drawRect(
        bar,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF2F6BFF),
      );

      final double x = band.x * size.width;
      canvas.drawLine(
        Offset(x, row.top),
        Offset(x, row.bottom),
        Paint()
          ..strokeWidth = 3
          ..color = const Color(0xFFE8552F),
      );
    }

    if (!editing) return;

    for (final ScoreAnchor anchor in anchors) {
      final double y = anchor.y * size.height;
      canvas.drawLine(
        Offset(anchor.xStart * size.width, y),
        Offset(anchor.xEnd * size.width, y),
        Paint()
          ..strokeWidth = 1.5
          ..color = const Color(0xFF1B9E4B),
      );

      final TextPainter label = TextPainter(
        text: TextSpan(
          text: ' ${_label(anchor.measure)} ',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final Rect chip = Rect.fromLTWH(
        anchor.xStart * size.width,
        y - label.height - 3,
        label.width,
        label.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(chip, const Radius.circular(3)),
        Paint()..color = const Color(0xFF1B9E4B),
      );
      label.paint(canvas, chip.topLeft);
    }
  }

  static String _label(double measure) => measure == measure.roundToDouble()
      ? '${measure.round()}'
      : measure.toStringAsFixed(1);

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.anchors != anchors ||
      old.highlight != highlight ||
      old.editing != editing;
}

/// 실시간 추종 화면의 위치 표시(토스풍).
///
/// 지금 줄 전체를 연한 파랑으로 감싸고, 지금 마디는 파란 둥근 테두리로,
/// 확인 전에는 점선으로 그린다. 칠해서 음표를 가리지 않는다.
class _FollowPainter extends CustomPainter {
  static const Color blue = Color(0xFF3182F6);
  static const Color blue50 = Color(0xFFE8F3FF);

  final MeasureBand? band;
  final MeasureBand? next;
  final FollowLook look;

  _FollowPainter({required this.band, required this.next, required this.look});

  @override
  void paint(Canvas canvas, Size size) {
    final MeasureBand? b = band;
    if (b == null) {
      // 페이지를 미리 넘겨 지금 마디가 이 쪽에 없다. 들어갈 마디를 알린다.
      final MeasureBand? n = next;
      if (n != null && look == FollowLook.tracking) _upcoming(canvas, size, n);
      return;
    }
    final double top = b.top * size.height;
    final double bottom = b.bottom * size.height;
    final Rect bar = Rect.fromLTRB(
      b.left * size.width - 3,
      top - 4,
      b.right * size.width + 3,
      bottom + 2,
    );

    if (look == FollowLook.start) {
      _dashed(canvas, RRect.fromRectAndRadius(bar, const Radius.circular(10)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = blue);
      _chip(canvas, '시작', Offset(bar.left + 4, bar.top - 6), blue, Colors.white);
      return;
    }

    // 줄 전체 배경(아주 연하게, 음표 위에 얹어도 읽히게)
    final Rect line = Rect.fromLTRB(size.width * 0.03, top - 6, size.width * 0.97, bottom + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(line, const Radius.circular(14)),
      Paint()..color = blue.withValues(alpha: 0.08),
    );

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = blue;
    final RRect measure = RRect.fromRectAndRadius(bar, const Radius.circular(10));
    if (look == FollowLook.provisional) {
      _dashed(canvas, measure, stroke);
    } else {
      canvas.drawRRect(measure, stroke);
      // 진행 위치: 음표 위에는 아주 연한 띠만 깔고, 정확한 위치는 줄 위
      // 바깥의 작은 점으로 알린다. 진한 선을 음표 위에 그으면 악보가 안 읽힌다.
      final double x = b.x * size.width;
      canvas.drawLine(
        Offset(x, top + (bottom - top) * 0.06),
        Offset(x, bottom - (bottom - top) * 0.06),
        Paint()
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round
          ..color = blue.withValues(alpha: 0.13),
      );
      canvas.drawCircle(Offset(x, bar.top - 5), 4.5, Paint()..color = blue);
    }

    final MeasureBand? n = next;
    if (n != null && look == FollowLook.tracking) {
      _chip(canvas, '다음', Offset(n.left * size.width + 4, n.top * size.height - 8), blue50, blue);
    }
  }

  /// 곧 들어갈 마디: 줄을 아주 연하게 깔고, 마디를 점선으로 두른 뒤 '다음'을 붙인다.
  static void _upcoming(Canvas canvas, Size size, MeasureBand n) {
    final double top = n.top * size.height;
    final double bottom = n.bottom * size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTRB(size.width * 0.03, top - 6, size.width * 0.97, bottom + 4),
          const Radius.circular(14)),
      Paint()..color = blue.withValues(alpha: 0.05),
    );
    final Rect bar = Rect.fromLTRB(
      n.left * size.width - 3,
      top - 4,
      n.right * size.width + 3,
      bottom + 2,
    );
    _dashed(
        canvas,
        RRect.fromRectAndRadius(bar, const Radius.circular(10)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = blue);
    _chip(canvas, '다음', Offset(bar.left + 4, bar.top - 6), blue, Colors.white);
  }

  static void _dashed(Canvas canvas, RRect r, Paint paint) {
    final Path path = Path()..addRRect(r);
    for (final ui.PathMetric m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 14) {
        canvas.drawPath(m.extractPath(d, d + 8), paint);
      }
    }
  }

  static void _chip(Canvas canvas, String text, Offset bottomLeft, Color bg, Color fg) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: 'Pretendard', fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final Rect r = Rect.fromLTWH(bottomLeft.dx, bottomLeft.dy - tp.height - 8, tp.width + 16, tp.height + 8);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)), Paint()..color = bg);
    tp.paint(canvas, Offset(r.left + 8, r.top + 4));
  }

  @override
  bool shouldRepaint(_FollowPainter old) => old.band != band || old.next != next || old.look != look;
}
