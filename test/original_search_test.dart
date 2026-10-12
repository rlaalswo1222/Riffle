import 'dart:async';
import 'dart:convert';

import 'package:barlink/services/original_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

OriginalCandidate candidate(String id,
        {bool official = false, int seconds = 180}) =>
    OriginalCandidate(id, id, official ? 'Artist - Topic' : 'Channel',
        Duration(seconds: seconds));

void main() {
  test('appends all pages, removes duplicate IDs and preserves earlier order',
      () async {
    int page = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      expected: const Duration(seconds: 180),
      close: () {},
      nextPage: () async => <List<OriginalCandidate>?>[
        <OriginalCandidate>[
          candidate('cover'),
          candidate('official', official: true, seconds: 240),
          candidate('near', official: true)
        ],
        <OriginalCandidate>[
          candidate('official'),
          candidate('new', official: true),
          candidate('new')
        ],
        <OriginalCandidate>[candidate('third')],
        null,
      ][page++],
    );
    addTearDown(search.dispose);
    await search.loadMore();
    expect(search.candidates.map((c) => c.id),
        <String>['near', 'official', 'cover']);
    await search.loadMore();
    await search.loadMore();
    expect(search.candidates.map((c) => c.id),
        <String>['near', 'official', 'cover', 'new', 'third']);
    await search.loadMore();
    await search.loadMore();
    expect(search.hasMore, isFalse);
    expect(page, 4);
  });

  test('overlapping loads share one request', () async {
    final Completer<List<OriginalCandidate>?> response =
        Completer<List<OriginalCandidate>?>();
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () {
        calls++;
        return response.future;
      },
    );
    addTearDown(search.dispose);
    final Future<void> first = search.loadMore();
    final Future<void> second = search.loadMore();
    expect(search.loading, isTrue);
    expect(calls, 1);
    response.complete(<OriginalCandidate>[candidate('one')]);
    await Future.wait(<Future<void>>[first, second]);
    expect(search.candidates, hasLength(1));
    expect(search.loading, isFalse);
  });

  test('a failed request retains results and can be retried', () async {
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async {
        calls++;
        if (calls == 2) throw StateError('offline');
        return <OriginalCandidate>[candidate(calls == 1 ? 'one' : 'two')];
      },
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await search.loadMore();
    expect(search.failed, isTrue);
    expect(search.hasMore, isTrue);
    expect(search.candidates.map((c) => c.id), <String>['one']);
    await search.loadMore();
    expect(search.failed, isFalse, reason: '${search.error}');
    expect(search.candidates.map((c) => c.id), <String>['one', 'two']);
  });

  test('an empty page does not discard a continuation', () async {
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () {},
      nextPage: () async => calls++ == 0
          ? <OriginalCandidate>[]
          : <OriginalCandidate>[candidate('later')],
    );
    addTearDown(search.dispose);
    await search.loadMore();
    expect(search.hasMore, isTrue);
    await search.loadMore();
    expect(search.candidates.single.id, 'later');
  });

  test('closing during a load ignores its result and closes only once',
      () async {
    final Completer<List<OriginalCandidate>?> response =
        Completer<List<OriginalCandidate>?>();
    int closes = 0;
    int notifications = 0;
    int calls = 0;
    final OriginalSearchSession search = OriginalSearchSession(
      close: () => closes++,
      nextPage: () {
        calls++;
        return response.future;
      },
    )..addListener(() => notifications++);
    final Future<void> pending = search.loadMore();
    search.dispose();
    search.dispose();
    response.complete(<OriginalCandidate>[candidate('late')]);
    await pending;
    await search.loadMore();
    expect(search.candidates, isEmpty);
    expect(closes, 1);
    expect(calls, 1);
    expect(notifications, 1);
  });

  test('YouTube continuation reaches a third page without estimatedResults',
      () async {
    final List<String> tokens = <String>[];
    final OriginalSearchSession search = OriginalAudio.startSearch(
      'Title',
      'Artist',
      httpClient: MockClient((http.Request request) async {
        if (request.method == 'GET') {
          expect(request.url.queryParameters['search_query'], 'Artist Title');
          return http.Response(
              '<script>var ytInitialData = ${jsonEncode(searchPage('aaaaaaaaaaa', 'page2', initial: true))};</script>',
              200,
              request: request);
        }
        final String token = (jsonDecode(request.body)
            as Map<String, dynamic>)['continuation'] as String;
        tokens.add(token);
        return http.Response(
            jsonEncode(token == 'page2'
                ? searchPage('bbbbbbbbbbb', 'page3')
                : searchPage('ccccccccccc', null)),
            200,
            request: request);
      }),
    );
    addTearDown(search.dispose);
    for (int i = 0; i < 4; i++) {
      await search.loadMore();
    }
    expect(search.failed, isFalse, reason: '${search.error}');
    expect(search.candidates.map((c) => c.id),
        <String>['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc']);
    expect(tokens, <String>['page2', 'page3']);
    expect(search.hasMore, isFalse);
  });

  test('YouTube retry uses the same continuation rather than restarting',
      () async {
    int posts = 0;
    final OriginalSearchSession search = OriginalAudio.startSearch(
      'Title',
      'Artist',
      httpClient: MockClient((http.Request request) async {
        if (request.method == 'GET') {
          return http.Response(
              '<script>var ytInitialData = ${jsonEncode(searchPage('aaaaaaaaaaa', 'page2', initial: true))};</script>',
              200,
              request: request);
        }
        expect(
            (jsonDecode(request.body) as Map<String, dynamic>)['continuation'],
            'page2');
        // Exhaust the library's own retry budget before retrying in the UI.
        if (++posts <= 5) {
          return http.Response('invalid json', 200, request: request);
        }
        return http.Response(jsonEncode(searchPage('bbbbbbbbbbb', null)), 200,
            request: request);
      }),
    );
    addTearDown(search.dispose);
    await search.loadMore();
    await search.loadMore();
    expect(search.failed, isTrue);
    expect(search.candidates, hasLength(1), reason: '${search.error}');
    await search.loadMore();
    expect(search.failed, isFalse);
    expect(search.candidates, hasLength(2));
    expect(posts, 6);
  });
}

Map<String, dynamic> searchPage(String id, String? token,
    {bool initial = false}) {
  final List<Map<String, dynamic>> contents = <Map<String, dynamic>>[
    <String, dynamic>{
      'itemSectionRenderer': <String, dynamic>{
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'videoRenderer': <String, dynamic>{
              'videoId': id,
              'title': <String, dynamic>{
                'runs': <Map<String, dynamic>>[
                  <String, dynamic>{'text': id}
                ]
              },
              'ownerText': <String, dynamic>{
                'runs': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'text': 'Artist - Topic',
                    'navigationEndpoint': <String, dynamic>{
                      'browseEndpoint': <String, dynamic>{
                        'browseId': 'UCaaaaaaaaaaaaaaaaaaaaaa'
                      }
                    },
                  }
                ]
              },
              'lengthText': <String, dynamic>{'simpleText': '3:00'},
            }
          },
        ]
      }
    },
    if (token != null)
      <String, dynamic>{
        'continuationItemRenderer': <String, dynamic>{
          'continuationEndpoint': <String, dynamic>{
            'continuationCommand': <String, dynamic>{'token': token}
          },
        }
      },
  ];
  if (initial) {
    return <String, dynamic>{
      'estimatedResults': '3',
      'contents': <String, dynamic>{
        'twoColumnSearchResultsRenderer': <String, dynamic>{
          'primaryContents': <String, dynamic>{
            'sectionListRenderer': <String, dynamic>{'contents': contents}
          },
        }
      },
    };
  }
  return <String, dynamic>{
    'onResponseReceivedCommands': <Map<String, dynamic>>[
      <String, dynamic>{
        'appendContinuationItemsAction': <String, dynamic>{
          'continuationItems': contents
        }
      },
    ]
  };
}
