import 'package:test/test.dart';
import 'package:thread_ripper/btr/downloader.dart';
import 'package:thread_ripper/link_tuner.dart';

void main() {
  late DateTime clock;
  late List<String> said;
  late RipperLinkTuner tuner;

  void pass(Duration time) => clock = clock.add(time);

  setUp(() {
    clock = DateTime(2026, 12, 1, 12);
    said = [];
    tuner = RipperLinkTuner(now: () => clock, onChange: said.add);
  });

  /// [count] first bytes of [ms], a second apart.
  void firstBytes(int ms, [int count = 20]) {
    for (var i = 0; i < count; i++) {
      tuner.noteFirstByte(ms);
      pass(const Duration(seconds: 1));
    }
  }

  group('the timings', () {
    test('as first set until enough first bytes were seen', () {
      final first = tuner.settings;
      expect(first.slowLink, isTrue);
      expect(first.firstByteTimeoutMs, 15000);
      expect(first.stallTimeoutMs, 12000);
      expect(first.hedgeDelayMs, 6000);
      expect(first.hedgeFloorMs, 3000);
      expect(first.raceGapMs, 2500);
      expect(first.concurrency, 4);
      firstBytes(900, 9);
      pass(const Duration(seconds: 30));
      // The same object: the downloader tells a change by it.
      expect(identical(tuner.settings, first), isTrue);
      expect(said, isEmpty);
    });

    test('a slowest tenth of two seconds: as first set', () {
      final first = tuner.settings;
      firstBytes(2000);
      pass(const Duration(seconds: 30));
      final s = tuner.settings;
      expect(s.firstByteTimeoutMs, 15000);
      expect(s.stallTimeoutMs, 12000);
      expect(s.hedgeDelayMs, 6000);
      expect(s.hedgeFloorMs, 3000);
      expect(s.raceGapMs, 2500);
      expect(identical(s, first), isTrue);
      expect(said, isEmpty);
    });

    test('a quick link: a second node sooner, the timeouts as they were', () {
      firstBytes(700);
      pass(const Duration(seconds: 30));
      final s = tuner.settings;
      // A timeout that is too short throws away what was waited for.
      expect(s.firstByteTimeoutMs, 15000);
      expect(s.stallTimeoutMs, 12000);
      expect(s.hedgeDelayMs, 3000);
      expect(s.hedgeFloorMs, 2000);
      expect(s.raceGapMs, 1500);
      expect(said.single, startsWith('time p90=700'));
    });

    test('a slow one: longer, up to their ceilings', () {
      firstBytes(5000);
      pass(const Duration(seconds: 30));
      var s = tuner.settings;
      expect(s.firstByteTimeoutMs, 22000);
      expect(s.stallTimeoutMs, 18000);
      expect(s.hedgeDelayMs, 12000);
      expect(s.hedgeFloorMs, 6000);
      expect(s.raceGapMs, 6000);
      firstBytes(9000, 60);
      pass(const Duration(seconds: 30));
      s = tuner.settings;
      expect(s.firstByteTimeoutMs, 30000);
      expect(s.stallTimeoutMs, 25000);
    });

    test('the slowest tenth, not the rest', () {
      firstBytes(800, 17);
      firstBytes(4000, 3);
      expect(tuner.firstByteP90, 4000);
      firstBytes(800, 20);
      // Three in forty now.
      expect(tuner.firstByteP90, 800);
    });

    test('quick to rise: the last requests, whatever the minutes before', () {
      // Five minutes of a quick link, then it slows.
      firstBytes(700, 300);
      expect(tuner.firstByteP90, 700);
      firstBytes(5000, 7);
      // Seven in three hundred and seven, but seven of the last sixty.
      expect(tuner.firstByteP90, 5000);
      pass(const Duration(seconds: 30));
      expect(tuner.settings.firstByteTimeoutMs, 22000);
      expect(tuner.settings.hedgeDelayMs, 12000);
    });

    test('slow to fall: a slow minute is remembered for ten', () {
      firstBytes(700, 200);
      firstBytes(5000, 60);
      // A quick minute after it: the last sixty are all quick.
      firstBytes(700, 60);
      // 60 of 320 were slow.
      expect(tuner.firstByteP90, 5000);
      pass(const Duration(seconds: 30));
      expect(tuner.settings.hedgeDelayMs, 12000);
      // Ten minutes after the slow ones (two since the last of the quick).
      pass(const Duration(minutes: 8, seconds: 30));
      firstBytes(700, 20);
      expect(tuner.firstByteP90, 700);
      pass(const Duration(seconds: 30));
      expect(tuner.settings.hedgeDelayMs, 3000);
      expect(tuner.settings.firstByteTimeoutMs, 15000);
    });

    test('ten minutes of requests are kept, not the last sixty', () {
      // 80 a minute, as on a phone's first record: a slow tenth spread over
      // them is seen whole.
      for (var i = 0; i < 800; i++) {
        tuner.noteFirstByte(i % 8 == 0 ? 4000 : 600);
        pass(const Duration(milliseconds: 700));
      }
      expect(tuner.firstByteP90, 4000);
    });

    test('many timeouts beside the answers: not below the ones first set', () {
      firstBytes(700);
      // A fifth of the requests time out: the short timeout may be why.
      for (var i = 0; i < 5; i++) {
        tuner.noteTimeout();
      }
      expect(tuner.timeoutShare, closeTo(0.2, 0.001));
      pass(const Duration(seconds: 30));
      var s = tuner.settings;
      expect(s.firstByteTimeoutMs, 15000);
      expect(s.stallTimeoutMs, 12000);
      expect(s.hedgeDelayMs, 6000);
      expect(s.raceGapMs, 2500);
      // Nearly half: half as much again.
      for (var i = 0; i < 12; i++) {
        tuner.noteTimeout();
      }
      pass(const Duration(seconds: 30));
      s = tuner.settings;
      expect(s.firstByteTimeoutMs, 22500);
      expect(s.stallTimeoutMs, 18000);
    });

    test('what was seen long ago is not the link now', () {
      firstBytes(700);
      pass(const Duration(seconds: 30));
      expect(tuner.settings.hedgeDelayMs, 3000);
      pass(const Duration(minutes: 11));
      expect(tuner.firstByteP90, isNull);
      // Nothing new to go by: they stay as they were.
      expect(tuner.settings.hedgeDelayMs, 3000);
    });

    test('settings change no more often than every twenty seconds', () {
      firstBytes(700);
      pass(const Duration(seconds: 30));
      final short = tuner.settings;
      firstBytes(5000, 10);
      // Ten seconds on.
      expect(identical(tuner.settings, short), isTrue);
      firstBytes(5000, 15);
      expect(identical(tuner.settings, short), isFalse);
    });
  });

  group('the download ahead', () {
    test('ten minutes while the link was not gone', () {
      expect(tuner.bufferSeconds, 600);
      tuner.noteOutage(const Duration(seconds: 9));
      expect(tuner.longestOutageSeconds, 0);
      expect(tuner.bufferSeconds, 600);
    });

    test('twice the longest outage and two minutes, to twenty', () {
      tuner.noteOutage(const Duration(seconds: 90));
      // 300 s wanted: the ten minutes cover it.
      expect(tuner.bufferSeconds, 600);
      expect(said, isEmpty);
      tuner.noteOutage(const Duration(minutes: 5));
      expect(tuner.bufferSeconds, 720);
      expect(said.single, 'buffer out=300 secs=720');
      tuner.noteOutage(const Duration(minutes: 12));
      expect(tuner.bufferSeconds, 1200);
    });

    test('an hour without one, and it is ten minutes again', () {
      tuner.noteOutage(const Duration(minutes: 6));
      expect(tuner.bufferSeconds, 840);
      pass(const Duration(minutes: 59));
      expect(tuner.bufferSeconds, 840);
      pass(const Duration(minutes: 2));
      expect(tuner.bufferSeconds, 600);
    });
  });

  group('the connections', () {
    /// A speed with the count in use, ten seconds after the last.
    void speed(int kbps, {bool mayExplore = true}) {
      tuner.noteSpeed(kbps, mayExplore: mayExplore);
      pass(const Duration(seconds: 10));
    }

    test('tried in turn, one measurement each', () {
      expect(tuner.concurrency, 4);
      final used = <int>[];
      for (var i = 0; i < 9; i++) {
        used.add(tuner.concurrency);
        speed(1000);
      }
      expect(used, [4, 2, 6, 4, 2, 6, 4, 2, 6]);
      expect(tuner.settings.concurrency, tuner.concurrency);
    });

    test('the best by its median, when a fifth better', () {
      // 4 and 2 the same, 6 half as fast again.
      const by = {4: 1000, 2: 1000, 6: 1500};
      for (var i = 0; i < 9; i++) {
        speed(by[tuner.concurrency]!);
      }
      expect(tuner.concurrency, 6);
      expect(tuner.medianWith(6), 1500);
      expect(said.last, startsWith('conn '));
      // It stays there.
      for (var i = 0; i < 5; i++) {
        speed(1500);
        expect(tuner.concurrency, 6);
      }
    });

    test('not for a tenth: the one in use stays', () {
      const by = {4: 1000, 2: 1100, 6: 900};
      for (var i = 0; i < 9; i++) {
        speed(by[tuner.concurrency]!);
      }
      // The last one tried was 6, and 2 is a fifth better than it.
      expect(tuner.concurrency, 2);
      for (var i = 0; i < 4; i++) {
        speed(by[tuner.concurrency]!);
      }
      expect(tuner.concurrency, 2);
    });

    test('one measurement that is far off does not decide', () {
      // 2 as fast as 4, but for one window that straddled an outage.
      final two = [1000, 50, 1000];
      final four = [1000, 1000, 1000];
      final six = [1000, 1000, 1000];
      for (var i = 0; i < 9; i++) {
        final list = switch (tuner.concurrency) {
          2 => two,
          4 => four,
          _ => six,
        };
        speed(list.removeAt(0));
      }
      expect(tuner.medianWith(2), 1000);
      // Nothing is a fifth better than the last one tried.
      expect(tuner.concurrency, 6);
    });

    test('nothing is tried while the player waits on the download', () {
      for (var i = 0; i < 6; i++) {
        speed(1000, mayExplore: false);
        expect(tuner.concurrency, 4);
      }
      expect(said, isEmpty);
    });

    test('trying stops when the player begins to wait: back to the best', () {
      speed(1000); // 4, then 2 is tried
      speed(1000); // 2, then 6
      expect(tuner.concurrency, 6);
      // 4 and 2 have one measurement each, 6 none: nothing is known to be
      // better, and it stays where it is.
      speed(900, mayExplore: false);
      expect(tuner.concurrency, 6);
      // Once 4 is measured enough, an unmeasured count gives way to it.
      tuner = RipperLinkTuner(now: () => clock);
      for (var i = 0; i < 3; i++) {
        speed(1000, mayExplore: false);
      }
      speed(1000); // 4 measured: 2 is tried
      expect(tuner.concurrency, 2);
      speed(400, mayExplore: false);
      expect(tuner.concurrency, 4);
    });

    test('measured long ago, a count is tried again', () {
      const by = {4: 1000, 2: 1000, 6: 1500};
      for (var i = 0; i < 9; i++) {
        speed(by[tuner.concurrency]!);
      }
      expect(tuner.concurrency, 6);
      // Twenty-five minutes on 6 alone.
      for (var i = 0; i < 150; i++) {
        speed(1500, mayExplore: false);
      }
      expect(tuner.medianWith(4), isNull);
      expect(tuner.concurrency, 6);
      speed(1500);
      expect(tuner.concurrency, isNot(6));
    });
  });

  test('the settings are a slow link\'s, and survive the downloader', () {
    firstBytes(700);
    pass(const Duration(seconds: 30));
    tuner
      ..noteSpeed(1000, mayExplore: true)
      ..noteOutage(const Duration(minutes: 5));
    final s = tuner.settings;
    expect(s.concurrency, 2);
    // What the downloader does to settings before it uses them.
    final normalized = s.normalized();
    expect(identical(normalized, s), isTrue);
    final other = s.withConcurrency(6);
    expect(other.concurrency, 6);
    expect(other.slowLink, isTrue);
    expect(other.firstByteTimeoutMs, 15000);
    expect(other.hedgeDelayMs, 3000);
    expect(other.hedgeFloorMs, 2000);
    expect(other.raceGapMs, 1500);
    expect(other.pieceRounds, 40);
    // A count no slow link is given.
    expect(
      const RipperDownloadSettings.slowLink(concurrency: 64)
          .normalized()
          .concurrency,
      8,
    );
    expect(tuner.describe(), contains('连接数 2'));
    // How many measurements each count has: one with 4, none with the rest.
    expect(tuner.describe(), contains('4 条 ?〔1 个〕，2 条 ?〔0 个〕'));
    expect(tuner.describe(), contains('提前缓冲 12 分钟'));
  });
}
