// The quality changed as a video plays.
import 'package:test/test.dart';
import 'package:thread_ripper/quality_watch.dart';

// 4K at 16 Mbit/s, 1080P at 4, 720P at 2, 480P at 1.
const offered = [
  (quality: 120, bandwidth: 16000000),
  (quality: 80, bandwidth: 4000000),
  (quality: 64, bandwidth: 2000000),
  (quality: 32, bandwidth: 1000000),
];

DateTime at(int seconds) =>
    DateTime(2026, 11, 24).add(Duration(seconds: seconds));

void main() {
  test('two slow speeds while the player waited lower the quality', () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    // 4.5 Mbit/s for a stream of 4: not 1.2 times it.
    expect(watch.speed(4500, sustained: true, now: at(0)), isNull);
    // The same run of the meter, a second on: not a second finding.
    expect(watch.speed(4400, sustained: true, now: at(1)), isNull);
    // 720P needs 3 with the headroom: carried by 4.4.
    expect(watch.speed(4400, sustained: true, now: at(5)), 64);
    expect(watch.current, 64);
  });

  test('down as far as the speed carries, the lowest if nothing is', () {
    final watch = RipperQualityWatch(offered: offered, current: 120);
    expect(watch.speed(1600, sustained: true, now: at(0)), isNull);
    expect(watch.speed(1600, sustained: true, now: at(5)), 32);
    final poor = RipperQualityWatch(offered: offered, current: 80);
    expect(poor.speed(300, sustained: true, now: at(0)), isNull);
    expect(poor.speed(300, sustained: true, now: at(5)), 32);
    // Nothing below the lowest.
    expect(poor.speed(300, sustained: true, now: at(10)), isNull);
    expect(poor.speed(300, sustained: true, now: at(15)), isNull);
  });

  test('a speed that carries the quality between two slow ones', () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    expect(watch.speed(4000, sustained: true, now: at(0)), isNull);
    // After a seek, say: the player waited, and 20 Mbit/s came in.
    expect(watch.speed(20000, sustained: true, now: at(3)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(6)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(11)), 64);
  });

  test('slow speeds a minute apart are two dips, not one', () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    expect(watch.speed(4000, sustained: true, now: at(0)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(90)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(95)), 64);
  });

  test("one window's speed never lowers", () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    for (var i = 0; i < 10; i++) {
      expect(watch.speed(1000, sustained: false, now: at(i * 5)), isNull);
    }
    expect(watch.current, 80);
  });

  test('at twice the speed a quality needs twice its bitrate', () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    // 8 Mbit/s carries 1080P, not at 2x.
    expect(watch.speed(8000, sustained: true, now: at(0), rate: 2), isNull);
    expect(watch.speed(8000, sustained: true, now: at(5), rate: 2), 64);
  });

  test('speeds that carry the next quality for a while raise it', () {
    final watch = RipperQualityWatch(offered: offered, current: 64);
    // 1080P needs 6 Mbit/s with the headroom.
    expect(watch.speed(9000, sustained: false, now: at(0)), isNull);
    expect(watch.speed(8000, sustained: false, now: at(10)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(21)), 80);
    expect(watch.current, 80);
  });

  test('raised to the best the least speed seen carries', () {
    final watch = RipperQualityWatch(offered: offered, current: 32);
    expect(watch.speed(40000, sustained: false, now: at(0)), isNull);
    expect(watch.speed(30000, sustained: false, now: at(10)), isNull);
    // 4K needs 24: carried by the least, 30.
    expect(watch.speed(50000, sustained: false, now: at(20)), 120);
    final less = RipperQualityWatch(offered: offered, current: 32);
    expect(less.speed(40000, sustained: false, now: at(0)), isNull);
    expect(less.speed(7000, sustained: false, now: at(10)), isNull);
    // The least was 7: 1080P, not 4K.
    expect(less.speed(50000, sustained: false, now: at(20)), 80);
  });

  test('never above the quality set', () {
    final watch = RipperQualityWatch(offered: offered.sublist(1), current: 64);
    expect(watch.speed(90000, sustained: false, now: at(0)), isNull);
    expect(watch.speed(90000, sustained: false, now: at(20)), 80);
    for (var i = 3; i < 20; i++) {
      expect(watch.speed(90000, sustained: false, now: at(i * 30)), isNull);
    }
  });

  test('one speed that does not carry it starts the wait over', () {
    final watch = RipperQualityWatch(offered: offered, current: 64);
    expect(watch.speed(9000, sustained: false, now: at(0)), isNull);
    expect(watch.speed(5000, sustained: false, now: at(10)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(21)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(30)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(41)), 80);
  });

  test('no raise within a minute of a lowering', () {
    final watch = RipperQualityWatch(offered: offered, current: 80);
    expect(watch.speed(4000, sustained: true, now: at(0)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(5)), 64);
    expect(watch.speed(9000, sustained: false, now: at(10)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(40)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(64)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(66)), 80);
  });

  test('a raise taken back soon is not tried again for ten minutes', () {
    final watch = RipperQualityWatch(offered: offered, current: 64);
    expect(watch.speed(9000, sustained: false, now: at(0)), isNull);
    expect(watch.speed(9000, sustained: false, now: at(20)), 80);
    // It did not hold.
    expect(watch.speed(4000, sustained: true, now: at(40)), isNull);
    expect(watch.speed(4000, sustained: true, now: at(45)), 64);
    for (var s = 60; s < 45 + 600; s += 30) {
      expect(watch.speed(9000, sustained: false, now: at(s)), isNull);
    }
    // Ten minutes after it was taken back (at 45 s), with the speed good
    // all the while.
    expect(watch.speed(9000, sustained: false, now: at(650)), 80);
  });

  test('a stream that states no bitrate: nothing to go by', () {
    const unknown = [
      (quality: 80, bandwidth: 0),
      (quality: 64, bandwidth: 2000000),
    ];
    final top = RipperQualityWatch(offered: unknown, current: 80);
    expect(top.speed(100, sustained: true, now: at(0)), isNull);
    expect(top.speed(100, sustained: true, now: at(5)), isNull);
    final below = RipperQualityWatch(offered: unknown, current: 64);
    expect(below.speed(90000, sustained: false, now: at(0)), isNull);
    expect(below.speed(90000, sustained: false, now: at(30)), isNull);
  });

  test('a quality that is not among those offered', () {
    final watch = RipperQualityWatch(offered: offered, current: 16);
    expect(watch.speed(100, sustained: true, now: at(0)), isNull);
    expect(watch.speed(100, sustained: true, now: at(5)), isNull);
  });
}
