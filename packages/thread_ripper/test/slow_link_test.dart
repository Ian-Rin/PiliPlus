// RipperDownloadSettings.slowLink (the app's 机上模式) on scripted networks
// like an airliner's satellite link, beside upstream's settings on the same
// network: what the slow link's timings spare, and what they wait out.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thread_ripper/btr/downloader.dart';
import 'package:thread_ripper/btr/range_proxy.dart';

import 'btr_harness.dart';

void main() {
  final defaults = Map<String, Object?>.from(
    (jsonDecode(File('test/fixtures/btr_scenarios.json').readAsStringSync())
            as Map)['defaults']
        as Map,
  );

  List<Map<String, Object?>> run(
    Map<String, Object?> scenario, {
    required bool slowLink,
  }) => runScenario(
    mergeScenario(defaults, {
      ...scenario,
      'settings': {'concurrency': 4, 'slowLink': slowLink},
    }),
  );

  List<Map<String, Object?>> of(List<Map<String, Object?>> events, String e) =>
      events.where((event) => event['e'] == e).toList();

  // A request answered after three round trips of 0.6 s (a new connection),
  // then 16 KiB every 300 ms: 53 KiB/s.
  const satellite = {
    'default': {'headMs': 1800, 'chunkBytes': 16384, 'chunkMs': 300},
  };

  test('a start asks one node for the head while that one answers', () {
    final scenario = {
      'network': satellite,
      'calls': [
        {'at': 0, 'start': 0, 'end': 65535, 'kind': 'meta'},
      ],
    };
    final slow = run(scenario, slowLink: true);
    expect(of(slow, 'fetch'), hasLength(1));
    expect(of(slow, 'abort'), isEmpty);
    expect(of(slow, 'done').single['good'], true);
    // Upstream's race on the same link: three nodes asked within 300 ms,
    // and the two that lose cut off (their connections closed).
    final fast = run(scenario, slowLink: false);
    expect(of(fast, 'fetch'), hasLength(3));
    expect(of(fast, 'abort'), hasLength(2));
  });

  test('a node that does not answer is raced after the gap', () {
    final slow = run({
      'network': {
        // Nothing comes back, but from the second node asked.
        'default': {'headMs': 60000, 'chunkBytes': 16384, 'chunkMs': 300},
        'hosts': {
          'upos-hz-mirrorakam.akamaized.net': {'headMs': 1800},
        },
      },
      'calls': [
        {'at': 0, 'start': 0, 'end': 65535, 'kind': 'meta'},
      ],
    }, slowLink: true);
    final fetches = of(slow, 'fetch');
    expect(fetches, hasLength(2));
    expect(fetches[0]['t'], 0);
    expect(fetches[1]['t'], 2500);
    expect(fetches[1]['host'], 'upos-hz-mirrorakam.akamaized.net');
    final done = of(slow, 'done').single;
    expect(done['good'], true);
    expect(done['hosts'], ['upos-hz-mirrorakam.akamaized.net']);
  });

  test('no piece is asked for twice while its first copy comes in', () {
    final scenario = {
      'network': satellite,
      'calls': [
        {
          'at': 0,
          'start': 0,
          'end': 262143,
          'kind': 'video',
          'startup': true,
        },
        {'at': 100, 'start': 262144, 'end': 786431, 'kind': 'video'},
      ],
    };
    final slow = run(scenario, slowLink: true);
    final asked = [
      for (final fetch in of(slow, 'fetch')) '${fetch['s']}-${fetch['x']}',
    ];
    expect(asked.toSet(), hasLength(asked.length), reason: '$asked');
    expect(of(slow, 'abort'), isEmpty);
    expect(of(slow, 'done').map((done) => done['good']), [true, true]);
    // Upstream's settings ask again for bytes on their way, and cut the
    // copies that lose.
    final fast = run(scenario, slowLink: false);
    expect(of(fast, 'fetch').length, greaterThan(asked.length));
    expect(of(fast, 'abort'), isNotEmpty);
  });

  test('a link gone for a minute and more is waited out', () {
    // Each node's first twenty requests fail after 3 s (nothing comes
    // back), then the link is there again.
    final scenario = {
      'runMs': 400000,
      'network': {
        ...satellite,
        'requests': [
          {'host': '*', 'fromNth': 0, 'headMs': 3000, 'networkError': true},
          {'host': '*', 'fromNth': 20, 'headMs': 1800, 'networkError': false},
        ],
      },
      'calls': [
        {'at': 0, 'start': 65536, 'end': 327679, 'kind': 'video'},
      ],
    };
    final slow = run(scenario, slowLink: true);
    expect(of(slow, 'fail'), isEmpty);
    final done = of(slow, 'done').single;
    expect(done['good'], true);
    expect(done['t'] as num, greaterThan(60000));
    // Upstream's three rounds are over before it is back.
    final fast = run(scenario, slowLink: false);
    expect(of(fast, 'done'), isEmpty);
    expect(of(fast, 'fail'), hasLength(1));
  });

  test('upstream\'s settings are what they were', () {
    const settings = RipperDownloadSettings();
    expect(settings.slowLink, false);
    expect(settings.pieceRounds, 3);
    expect(settings.pieceRetryWindowMs, 25000);
    expect(settings.roundPauseMaxMs, 2000);
    expect(settings.hedgeFloorMs, 250);
    expect(settings.raceGapMs, 0);
    expect(
      [for (var r = 1; r < 6; r++) roundPause(r)],
      [
        500,
        1000,
        2000,
        2000,
        2000,
      ],
    );
    // A slow link's survive the downloader's own look at them.
    final slow = const RipperDownloadSettings.slowLink().normalized();
    expect(slow.slowLink, true);
    expect(slow.concurrency, 4);
    expect(slow.stallTimeoutMs, 12000);
    expect(slow.withConcurrency(8).hedgeDelayMs, 6000);
    expect(roundPause(60, slow.roundPauseMaxMs), 5000);
  });

  test('a slow link\'s windows are a quarter the size', () {
    int size(String kind, bool first, bool slow) =>
        BtrRangeProxy.windowBytes(kind: kind, first: first, slowLink: slow);
    expect(size('video', true, false), 1024 * 1024);
    expect(size('video', false, false), 2 * 1024 * 1024);
    expect(size('audio', true, false), 128 * 1024);
    expect(size('audio', false, false), 256 * 1024);
    expect(size('video', true, true), 256 * 1024);
    expect(size('video', false, true), 512 * 1024);
    expect(size('audio', true, true), 96 * 1024);
    expect(size('audio', false, true), 128 * 1024);
  });
}
