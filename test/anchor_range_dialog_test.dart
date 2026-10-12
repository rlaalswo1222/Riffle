import 'package:barlink/widgets/anchor_range_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('적용할 때 입력 포커스를 먼저 해제하고 결과를 반환한다', (WidgetTester tester) async {
    AnchorRangeResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => FilledButton(
            onPressed: () async {
              result = await showDialog<AnchorRangeResult>(
                context: context,
                builder: (_) => const AnchorRangeDialog(
                  start: 1,
                  end: 5,
                  canDelete: false,
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '13');
    await tester.enterText(find.byType(TextField).at(1), '17');
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.start, 13);
    expect(result!.end, 17);
    expect(find.byType(AnchorRangeDialog), findsNothing);
  });

  testWidgets('잘못된 범위는 다이얼로그에서 즉시 안내한다', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => FilledButton(
            onPressed: () => showDialog<AnchorRangeResult>(
              context: context,
              builder: (_) => const AnchorRangeDialog(
                start: 1,
                end: 5,
                canDelete: false,
              ),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '17');
    await tester.enterText(find.byType(TextField).at(1), '13');
    await tester.tap(find.text('적용'));
    await tester.pump();

    expect(find.text('끝 마디는 시작 마디보다 큰 숫자여야 합니다.'), findsOneWidget);
    expect(find.byType(AnchorRangeDialog), findsOneWidget);
  });
}
