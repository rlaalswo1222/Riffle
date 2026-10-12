import 'package:barlink/screens/local_sync_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('서버나 방 생성 없이 로컬 업로드 화면으로 시작한다', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LocalSyncScreen()));

    expect(find.text('로컬 악보 동기화 · 서버 사용 안 함'), findsOneWidget);
    expect(find.text('악보를 최대 6개 올려보세요'), findsOneWidget);
    expect(find.text('PDF 악보 선택'), findsOneWidget);
    expect(find.textContaining('악보 업로드 거절'), findsNothing);
    expect(find.textContaining('방 만들기'), findsNothing);
  });
}
