import 'package:flutter/material.dart';

/// 토스 디자인을 기준으로 한 색·글자·공통 위젯.
///
/// 연회색 바탕 위에 흰 카드, 크고 굵은 질문형 제목, 화면 아래 꽉 찬 버튼,
/// "~해요" 말투. 강조색은 파랑 하나만 쓰고 초록·빨강은 상태에만 쓴다.
class Toss {
  static const Color white = Color(0xFFFFFFFF);
  static const Color g50 = Color(0xFFF9FAFB);
  static const Color g100 = Color(0xFFF2F4F6);
  static const Color g200 = Color(0xFFE5E8EB);
  static const Color g300 = Color(0xFFD1D6DB);
  static const Color g400 = Color(0xFFB0B8C1);
  static const Color g500 = Color(0xFF8B95A1);
  static const Color g600 = Color(0xFF6B7684);
  static const Color g700 = Color(0xFF4E5968);
  static const Color g800 = Color(0xFF333D4B);
  static const Color g900 = Color(0xFF191F28);
  static const Color blue = Color(0xFF3182F6);
  static const Color bluePressed = Color(0xFF1B64DA);
  static const Color blue50 = Color(0xFFE8F3FF);
  static const Color green = Color(0xFF03B26C);
  static const Color red = Color(0xFFF04452);

  static const String font = 'Pretendard';

  static const TextStyle title = TextStyle(
      fontFamily: font, fontSize: 24, height: 1.4, fontWeight: FontWeight.w700, color: g900, letterSpacing: -0.6);
  static const TextStyle subtitle = TextStyle(
      fontFamily: font, fontSize: 18, height: 1.4, fontWeight: FontWeight.w700, color: g900, letterSpacing: -0.4);
  static const TextStyle body = TextStyle(
      fontFamily: font, fontSize: 15, height: 1.45, fontWeight: FontWeight.w600, color: g900, letterSpacing: -0.2);
  static const TextStyle caption = TextStyle(
      fontFamily: font, fontSize: 13.5, height: 1.45, fontWeight: FontWeight.w500, color: g600, letterSpacing: -0.1);
  static const TextStyle label = TextStyle(
      fontFamily: font, fontSize: 13, fontWeight: FontWeight.w600, color: g500);
  static const TextStyle action = TextStyle(
      fontFamily: font, fontSize: 14, fontWeight: FontWeight.w600, color: blue);

  static ThemeData theme() => ThemeData(
        useMaterial3: true,
        fontFamily: font,
        scaffoldBackgroundColor: g100,
        colorScheme: ColorScheme.fromSeed(seedColor: blue, primary: blue, surface: white),
        splashFactory: InkSparkle.splashFactory,
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: g800,
          contentTextStyle: const TextStyle(
              fontFamily: font, fontSize: 14.5, fontWeight: FontWeight.w600, color: white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: white,
          showDragHandle: true,
          dragHandleColor: g300,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        ),
      );

  static void toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 화면 아래 꽉 찬 버튼. [soft]면 연한 파랑 바탕.
class TossButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool soft;
  final double height;

  const TossButton(this.text, {super.key, this.onPressed, this.soft = false, this.height = 56});

  @override
  Widget build(BuildContext context) {
    final Color bg = soft ? Toss.blue50 : Toss.blue;
    final Color fg = soft ? Toss.blue : Toss.white;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: Toss.g200,
          disabledForegroundColor: Toss.g400,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontFamily: Toss.font, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        child: Text(text),
      ),
    );
  }
}

/// 흰 카드.
class TossCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const TossCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(color: Toss.white, borderRadius: BorderRadius.circular(20)),
        child: child,
      );
}

/// 목록의 한 줄: 왼쪽 아이콘, 제목·설명, 오른쪽 상태나 동작.
class TossRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const TossRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: Toss.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(subtitle!, style: Toss.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[const SizedBox(width: 10), trailing!],
            ],
          ),
        ),
      );
}

/// 둥근 사각 아이콘 자리(글자 하나 또는 아이콘).
class TossIconBox extends StatelessWidget {
  final String? letter;
  final IconData? icon;
  final bool accent;
  final Color? color;

  const TossIconBox({super.key, this.letter, this.icon, this.accent = false, this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color ?? (accent ? Toss.blue50 : Toss.g100),
          borderRadius: BorderRadius.circular(12),
        ),
        child: icon != null
            ? Icon(icon, size: 21, color: color != null ? Toss.white : (accent ? Toss.blue : Toss.g600))
            : Text(letter ?? '',
                style: TextStyle(
                    fontFamily: Toss.font,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: accent ? Toss.blue : Toss.g600)),
      );
}

/// 상태 동그라미: 완료(초록 체크), 주의(빨강 느낌표), 진행(파랑 점).
class TossStatus extends StatelessWidget {
  final bool ok;
  final bool busy;

  const TossStatus({super.key, this.ok = true, this.busy = false});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2.6, color: Toss.blue),
        ),
      );
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: ok ? Toss.green : Toss.red, shape: BoxShape.circle),
      child: Icon(ok ? Icons.check_rounded : Icons.priority_high_rounded, size: 15, color: Toss.white),
    );
  }
}

/// 토스식 바텀시트. 제목과 설명, 내용, 아래 버튼.
Future<T?> showTossSheet<T>({
  required BuildContext context,
  required String title,
  String? description,
  required Widget child,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Toss.title.copyWith(fontSize: 21)),
            if (description != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(description, style: Toss.caption.copyWith(fontSize: 14.5)),
            ],
            const SizedBox(height: 16),
            Flexible(child: child),
          ],
        ),
      ),
    ),
  );
}
