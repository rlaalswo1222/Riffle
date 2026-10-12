import 'dart:async';

import 'package:barlink/services/original_audio.dart';
import 'package:barlink/ui/toss.dart';
import 'package:barlink/widgets/original_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<OriginalCandidate> songs(int first, int count) => <OriginalCandidate>[
      for (int i = first; i < first + count; i++)
        OriginalCandidate(
            '$i', 'Song$i', 'Channel', const Duration(minutes: 3)),
    ];

Future<void> openPicker(WidgetTester tester, OriginalSearchSession search,
    void Function(Object?) onResult) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
    builder: (BuildContext context) => Scaffold(
        body: TextButton(
      onPressed: () async {
        try {
          onResult(await showTossSheet<Object>(
            context: context,
            title: '원곡을 골라 주세요',
            description: '원곡과 맞춰 두면 위치를 더 정확하게 따라가요',
            child: OriginalPicker(search: search),
          ));
        } finally {
          search.dispose();
        }
      },
      child: const Text('열기'),
    )),
  )));
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'scrolling appends more than five candidates and retains selection',
      (WidgetTester tester) async {
    int calls = 0;
    Object? result;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async => <List<OriginalCandidate>?>[
        songs(1, 20),
        songs(21, 20),
        null,
      ][calls++],
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await openPicker(tester, search, (Object? value) => result = value);
    await tester.tap(find.text('Song2'));
    await tester.scrollUntilVisible(find.text('Song25'), 350,
        scrollable: find.byType(Scrollable));
    await tester.pumpAndSettle();
    expect(find.text('Song25'), findsOneWidget);
    expect(calls, 2);
    expect(search.candidates, hasLength(40));
    expect(find.text('휴대폰에 있는 파일 고르기'), findsOneWidget);
    await tester.tap(find.text('이 음원으로 할게요'));
    await tester.pumpAndSettle();
    expect((result as OriginalCandidate).id, '2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a candidate on a later page can be selected',
      (WidgetTester tester) async {
    int calls = 0;
    Object? result;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async => <List<OriginalCandidate>?>[
        songs(1, 20),
        songs(21, 20),
        null,
      ][calls++],
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await openPicker(tester, search, (Object? value) => result = value);
    await tester.scrollUntilVisible(find.text('Song25'), 350,
        scrollable: find.byType(Scrollable));
    await tester.tap(find.text('Song25'));
    await tester.tap(find.text('이 음원으로 할게요'));
    await tester.pumpAndSettle();
    expect((result as OriginalCandidate).id, '25');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed search offers retry and empty results have an end message',
      (WidgetTester tester) async {
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async {
        if (++calls == 1) throw StateError('offline');
        return null;
      },
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await openPicker(tester, search, (_) {});
    expect(find.text('다시 시도'), findsOneWidget);
    expect(calls, 1); // Does not automatically retry a failing request.
    expect(find.text('휴대폰에 있는 파일 고르기'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('검색 결과가 없어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
    expect(calls, 2);
    await tester.tap(find.text('휴대폰에 있는 파일 고르기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'file selection remains available while loading and closes the search',
      (WidgetTester tester) async {
    int calls = 0;
    int closes = 0;
    Object? result;
    final Completer<List<OriginalCandidate>?> next =
        Completer<List<OriginalCandidate>?>();
    final OriginalSearchSession search = OriginalSearchSession(
      close: () => closes++,
      nextPage: () async {
        if (++calls == 1) return songs(1, 20);
        return next.future;
      },
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await openPicker(tester, search, (Object? value) => result = value);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('휴대폰에 있는 파일 고르기'));
    await tester.pumpAndSettle();
    expect(result, OriginalPicker.fromFile);
    expect(closes, 1);
    next.complete(songs(21, 20));
    await tester.pumpAndSettle();
    expect(search.candidates, hasLength(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short page loads more to fill the list and shows its end',
      (WidgetTester tester) async {
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async => <List<OriginalCandidate>?>[
        songs(1, 1),
        songs(2, 1),
        null,
      ][calls++],
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await openPicker(tester, search, (_) {});
    expect(find.text('Song1'), findsOneWidget);
    expect(find.text('Song2'), findsOneWidget);
    expect(find.text('검색 결과를 모두 봤어요'), findsOneWidget);
    expect(calls, 3);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('이 음원으로 할게요'));
    await tester.pumpAndSettle();
  });
}
