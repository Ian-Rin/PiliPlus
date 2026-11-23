// The quality of a video changed as it plays, by the download speed.
//
// After Bilibili-thread-ripper's automatic quality (page-hook.js,
// driveAutoQuality), as RipperSpeedMemory is for the quality a video starts
// on. A browser changes the quality within its buffer, unseen; in the app a
// change opens the video again, two or three seconds of spinner. So where
// upstream looks every second and follows the speed, a change is made here
// only when it is worth that wait:
// - Down, when the player has been waiting on the download and what came in
//   is barely the bitrate played ([downAt]), twice, seconds apart: the
//   picture stands still as it is, and the wait buys one that plays.
// - Up, when every speed measured for a while ([upHold]) carries the next
//   quality with upstream's headroom, no sooner than [minGap] after the last
//   change, and never above the quality set.
// - A raise that had to be taken back soon is not tried again for [upRest]:
//   a connection at the edge of two qualities would go to and fro.
//
// The two speeds are the proxy's (RipperSpeedMeter): one measured while the
// player waited is what the connection does; one window's own speed is the
// least it does, which can speak for a raise but never for a lowering.

import 'package:thread_ripper/speed_memory.dart';

/// See the head of this file. One for a video, from its start to its end.
class RipperQualityWatch {
  RipperQualityWatch({required this.offered, required this.current})
    : assert(offered.isNotEmpty);

  /// The stream of the quality set first, then those of the qualities below
  /// it, best first, each with its bitrate in bits a second (0 if it states
  /// none), as for [RipperSpeedMemory.pick].
  final List<({int quality, int bandwidth})> offered;

  /// The quality playing.
  int current;

  /// Below the bitrate played times this, a speed measured while the player
  /// waited does not carry the quality: playback stops again and again.
  static const downAt = 1.2;

  /// Two such speeds this far apart at least (one run of the meter gives
  /// several within a second), and no further than [lowWithin].
  static const lowApart = Duration(seconds: 4);
  static const lowWithin = Duration(seconds: 60);

  static const minGap = Duration(seconds: 60);
  static const upHold = Duration(seconds: 20);
  static const upRest = Duration(minutes: 10);

  /// A raise followed by a lowering within this was a mistake.
  static const _raiseTested = Duration(minutes: 2);

  DateTime? _lowAt;
  DateTime? _goodSince;
  int _goodCount = 0;
  double _goodLeast = 0;
  DateTime? _changedAt;
  DateTime? _raisedAt;
  DateTime? _noRaiseUntil;

  static bool _carries(({int quality, int bandwidth}) stream, double kbps) =>
      stream.bandwidth > 0 &&
      stream.bandwidth * RipperSpeedMemory.headroom <= kbps * 1000;

  /// A speed the proxy measured (BtrRangeProxy.onSpeed), with the playback
  /// [rate] (at twice the speed a quality needs twice its bitrate). Returns
  /// the quality to change to, which is then [current]; null for none.
  int? speed(
    int kbps, {
    required bool sustained,
    required DateTime now,
    double rate = 1,
  }) {
    if (kbps <= 0) return null;
    final at = offered.indexWhere((stream) => stream.quality == current);
    if (at < 0) return null;
    final have = kbps / (rate > 0 ? rate : 1);

    if (sustained) {
      final playing = offered[at].bandwidth;
      final low =
          playing > 0 &&
          have * 1000 < playing * downAt &&
          at < offered.length - 1;
      if (!low) {
        _lowAt = null;
      } else {
        _dropGood();
        final first = _lowAt;
        if (first == null || now.difference(first) > lowWithin) {
          _lowAt = now;
          return null;
        }
        if (now.difference(first) < lowApart) return null;
        final raised = _raisedAt;
        if (raised != null && now.difference(raised) < _raiseTested) {
          _noRaiseUntil = now.add(upRest);
        }
        return _change(
          RipperSpeedMemory.pick(offered.sublist(at + 1), have.floor()),
          now,
        );
      }
    }

    if (at == 0) return null;
    // The next quality up: while it is not carried, no raise is on its way.
    if (!_carries(offered[at - 1], have)) {
      _dropGood();
      return null;
    }
    _goodSince ??= now;
    _goodCount++;
    _goodLeast = _goodCount == 1 || have < _goodLeast ? have : _goodLeast;
    final changed = _changedAt;
    final rest = _noRaiseUntil;
    if (_goodCount < 2 ||
        now.difference(_goodSince!) < upHold ||
        (changed != null && now.difference(changed) < minGap) ||
        (rest != null && now.isBefore(rest))) {
      return null;
    }
    // The best of those above that the least speed seen carries.
    final to = offered
        .sublist(0, at)
        .firstWhere((stream) => _carries(stream, _goodLeast));
    _raisedAt = now;
    return _change(to.quality, now);
  }

  void _dropGood() {
    _goodSince = null;
    _goodCount = 0;
  }

  int _change(int quality, DateTime now) {
    current = quality;
    _changedAt = now;
    _lowAt = null;
    _dropGood();
    return quality;
  }
}
