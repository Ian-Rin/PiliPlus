// What a link that comes and goes has carried lately, for one decision:
// whether the next video may start a quality above its lowest (the app's
// 机上模式, on an airliner's satellite Wi-Fi).
//
// RipperSpeedMemory keeps one speed, the last measured, and a quality is
// carried at half as much again. On such a link one measurement is a
// moment's luck: seconds apart it does 0.9 and 3.7 Mbit/s, and it is gone
// for a minute now and then. So here:
// - The speed is the median of what was measured in the last [window], and
//   there is none until [least] measurements are in: a window that took a
//   minute because the link was gone meanwhile, or one that came in a burst,
//   does not move it.
// - A stream is carried at [headroom] times its bitrate, not 1.5: what plays
//   through the minute without a link is what the minutes with one brought
//   beyond the bitrate.
// - A raise that had to be taken back ([failed]) is not tried again for
//   [rest], and what was measured before it is forgotten.
//
// The speeds are the proxy's (BtrRangeProxy.onSpeed), both kinds: on its
// slow link's small windows a window's own speed is, like the other, of the
// video track alone, with its sound and the next window sharing the link,
// so each is the least the link does.

/// See the head of this file.
class RipperLinkSpeed {
  RipperLinkSpeed({
    this.window = const Duration(minutes: 10),
    this.least = 4,
    this.headroom = 3.0,
    this.rest = const Duration(minutes: 10),
  });

  final Duration window;
  final int least;
  final double headroom;
  final Duration rest;

  static const _kept = 64;

  final _samples = <({int kbps, DateTime at})>[];
  DateTime? _restUntil;

  /// A speed the proxy measured, in kbit/s.
  void note(int kbps, {DateTime? now}) {
    if (kbps <= 0) return;
    _samples.add((kbps: kbps, at: now ?? DateTime.now()));
    if (_samples.length > _kept) _samples.removeAt(0);
  }

  /// The median of the last [window]'s speeds in kbit/s; null with fewer
  /// than [least] of them.
  int? median({DateTime? now}) {
    final at = now ?? DateTime.now();
    final recent = [
      for (final sample in _samples)
        if (!at.isBefore(sample.at) && at.difference(sample.at) <= window)
          sample.kbps,
    ]..sort();
    if (recent.length < least) return null;
    final mid = recent.length ~/ 2;
    return recent.length.isOdd
        ? recent[mid]
        : (recent[mid - 1] + recent[mid]) ~/ 2;
  }

  /// Whether a stream of [bitsPerSecond] (picture and sound together) may
  /// be started on. Not while nothing is known, nor after a raise that
  /// failed, nor for a stream that states no bitrate.
  bool carries(int bitsPerSecond, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final until = _restUntil;
    if (until != null && at.isBefore(until)) return false;
    final kbps = median(now: at);
    return kbps != null &&
        bitsPerSecond > 0 &&
        bitsPerSecond * headroom <= kbps * 1000;
  }

  /// The raised quality did not play, or nothing did.
  void failed({DateTime? now}) {
    _restUntil = (now ?? DateTime.now()).add(rest);
    _samples.clear();
  }

  void clear() {
    _samples.clear();
    _restUntil = null;
  }
}
