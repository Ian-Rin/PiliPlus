// The speed the app chooses a video's first quality by.
import 'package:test/test.dart';
import 'package:thread_ripper/btr/speed_meter.dart';

const mib = 1024 * 1024;

void main() {
  test('a run of windows the player waited on gives its speed', () {
    final meter = RipperSpeedMeter();
    // The first only starts the clock: part of it had arrived before.
    expect(meter.window(2 * mib, waited: true, now: 1000), isNull);
    // Too short yet.
    expect(meter.window(2 * mib, waited: true, now: 2500), isNull);
    // 4 MiB in 3.2 s: 10.0 Mbit/s.
    expect(meter.window(2 * mib, waited: true, now: 4200), 10485);
    // Goes on: 6 MiB in 5 s.
    expect(meter.window(2 * mib, waited: true, now: 6000), 10066);
  });

  test('a window that had arrived ends the run', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(2 * mib, waited: true, now: 0), isNull);
    expect(meter.window(2 * mib, waited: true, now: 2000), isNull);
    // The download is ahead of the player again.
    expect(meter.window(2 * mib, waited: false, now: 2100), isNull);
    // A new run starts its clock anew: nothing from 5 s of waiting counts.
    expect(meter.window(2 * mib, waited: true, now: 5000), isNull);
    expect(meter.window(2 * mib, waited: true, now: 6000), isNull);
    // 4 MiB in the 3.1 s since the run's clock started.
    expect(meter.window(2 * mib, waited: true, now: 8100), 10824);
  });

  test('a slow connection is measured on one window', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(mib, waited: true, now: 0), isNull);
    // 2 MiB in 8 s: 2.1 Mbit/s, and the run starts over.
    expect(meter.window(2 * mib, waited: true, now: 8000), 2097);
    expect(meter.window(2 * mib, waited: true, now: 9000), isNull);
    expect(meter.window(2 * mib, waited: true, now: 12000), 8388);
  });

  test('a long run is of its last seconds', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(2 * mib, waited: true, now: 0), isNull);
    // Fast for eight seconds: 16 MiB.
    for (var i = 1; i <= 7; i++) {
      meter.window(2 * mib, waited: true, now: i * 1000);
    }
    expect(meter.window(2 * mib, waited: true, now: 8000), 16777);
    // Then slow: 2 MiB in 4 s is what it says, not the average since 0.
    expect(meter.window(2 * mib, waited: true, now: 12000), 4194);
  });

  // An app suspended in the background finishes the window it was on when
  // it comes back: minutes that are not the connection's.
  test('a window that ends minutes after the one before is no speed', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(2 * mib, waited: true, now: 0), isNull);
    expect(meter.window(2 * mib, waited: true, now: 1000), isNull);
    // Ten minutes on: not 55 kbit/s, and the run starts over from here.
    expect(meter.window(2 * mib, waited: true, now: 601000), isNull);
    expect(meter.window(2 * mib, waited: true, now: 602000), isNull);
    expect(meter.window(2 * mib, waited: true, now: 604100), 10824);
  });

  test('half a minute is still the connection', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(2 * mib, waited: true, now: 0), isNull);
    // 2 MiB in 30 s: 0.56 Mbit/s, the slowest that is measured.
    expect(meter.window(2 * mib, waited: true, now: 30000), 559);
    expect(meter.window(2 * mib, waited: true, now: 60001), isNull);
  });

  test('let go of, a run starts with the next window', () {
    final meter = RipperSpeedMeter();
    expect(meter.window(2 * mib, waited: true, now: 0), isNull);
    expect(meter.window(2 * mib, waited: true, now: 2000), isNull);
    meter.reset();
    // Would have been 4 MiB in 4 s.
    expect(meter.window(2 * mib, waited: true, now: 4000), isNull);
    expect(meter.window(2 * mib, waited: true, now: 7100), 5412);
  });

  test('one window on its own: a least speed, or nothing', () {
    expect(RipperSpeedMeter.burst(2 * mib, 400), 41943);
    // Too small, too quick to say.
    expect(RipperSpeedMeter.burst(128 * 1024, 400), isNull);
    expect(RipperSpeedMeter.burst(2 * mib, 5), isNull);
  });
}
