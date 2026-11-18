import 'package:test/test.dart';
import 'package:thread_ripper/speed_memory.dart';

void main() {
  // 4K at 12 Mbit/s, 1080P60 at 6, 1080P at 3, 720P at 1.5, 360P at 0.4.
  const offered = [
    (quality: 120, bandwidth: 12000000),
    (quality: 116, bandwidth: 6000000),
    (quality: 80, bandwidth: 3000000),
    (quality: 64, bandwidth: 1500000),
    (quality: 16, bandwidth: 400000),
  ];

  group('the quality a video starts on', () {
    test('the one set when no speed is known', () {
      expect(RipperSpeedMemory.pick(offered, null), 120);
    });

    test('the one set when the speed carries it half as much again', () {
      expect(RipperSpeedMemory.pick(offered, 18000), 120);
      expect(RipperSpeedMemory.pick(offered, 50000), 120);
    });

    test('the best below it that the speed carries', () {
      // Short of 18 Mbit/s for 4K; 9 carries 1080P60.
      expect(RipperSpeedMemory.pick(offered, 17999), 116);
      expect(RipperSpeedMemory.pick(offered, 9000), 116);
      expect(RipperSpeedMemory.pick(offered, 8999), 80);
      expect(RipperSpeedMemory.pick(offered, 3000), 64);
    });

    test('the lowest when the speed carries none', () {
      expect(RipperSpeedMemory.pick(offered, 100), 16);
    });

    test('a stream that states no bitrate is taken to be carried', () {
      expect(
        RipperSpeedMemory.pick(const [
          (quality: 120, bandwidth: 12000000),
          (quality: 80, bandwidth: 0),
          (quality: 16, bandwidth: 400000),
        ], 1000),
        80,
      );
    });
  });

  group('the speed known', () {
    final t0 = DateTime(2026, 11, 18, 12);
    DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

    late RipperSpeedMemory memory;
    late Map<bool, String> kept;

    setUp(() {
      kept = {};
      memory = RipperSpeedMemory(
        load: (wifi) => kept[wifi],
        save: (wifi, value) => kept[wifi] = value,
      );
    });

    test('kept across a restart, and not written for every window', () {
      memory.note(40000, sustained: true, now: at(0));
      expect(kept[true], '40000:${at(0).millisecondsSinceEpoch}');
      // Within a tenth, a moment later: not written again.
      memory.note(41000, sustained: true, now: at(5));
      expect(kept[true], '40000:${at(0).millisecondsSinceEpoch}');
      memory.note(20000, sustained: true, now: at(10));
      expect(kept[true], '20000:${at(10).millisecondsSinceEpoch}');
      // As after a restart.
      final again = RipperSpeedMemory(load: (wifi) => kept[wifi]);
      expect(again.known(now: at(20)), 20000);
      expect(again.known(now: at(31 * 60)), isNull);
      // Nothing kept, or something else: no speed.
      expect(RipperSpeedMemory().known(now: at(0)), isNull);
      expect(
        RipperSpeedMemory(load: (_) => 'fast').known(now: at(0)),
        isNull,
      );
    });

    test('a measurement made while the player waited sets it, up or down', () {
      memory.note(40000, sustained: true, now: at(0));
      expect(memory.known(now: at(1)), 40000);
      memory.note(5000, sustained: true, now: at(60));
      expect(memory.known(now: at(61)), 5000);
    });

    test('one window raises it, never lowers it', () {
      memory.note(20000, sustained: false, now: at(0));
      expect(memory.known(now: at(1)), 20000);
      memory.note(8000, sustained: false, now: at(10));
      expect(memory.known(now: at(11)), 20000);
      memory.note(30000, sustained: false, now: at(20));
      expect(memory.known(now: at(21)), 30000);
    });

    test('against a measurement made lately one window counts from twice '
        'as much', () {
      memory.note(5000, sustained: true, now: at(0));
      memory.note(9000, sustained: false, now: at(30));
      expect(memory.known(now: at(31)), 5000);
      memory.note(10000, sustained: false, now: at(40));
      expect(memory.known(now: at(41)), 10000);
      // Ten minutes on the measurement no longer outweighs a window.
      memory.note(12000, sustained: false, now: at(700));
      expect(memory.known(now: at(701)), 12000);
    });

    test('forgotten after half an hour', () {
      memory.note(3000, sustained: true, now: at(0));
      expect(memory.known(now: at(29 * 60)), 3000);
      expect(memory.known(now: at(31 * 60)), isNull);
    });

    test('Wi-Fi and the mobile network each have their own', () {
      memory.note(40000, sustained: true, now: at(0));
      memory.onWifi = false;
      expect(memory.known(now: at(1)), isNull);
      memory.note(2000, sustained: true, now: at(2));
      expect(memory.known(now: at(3)), 2000);
      memory.onWifi = true;
      expect(memory.known(now: at(4)), 40000);
    });
  });
}
