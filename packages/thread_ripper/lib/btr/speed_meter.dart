// What the download of a video track does when the player waits on it: the
// speed the app chooses a video's first quality by (see RipperSpeed in the
// app). After the two speeds Bilibili-thread-ripper tells apart for its
// automatic quality (page-hook.js, measureAutoSpeed), measured here on the
// windows the proxy hands the player instead of on a browser's buffer.

/// The speed of a run of windows the player took before they had all
/// arrived: it was waiting on the download, so what came in is what the
/// connection does. A window that had arrived when the player took it says
/// only that the connection does at least its own speed (see
/// [RipperSpeedMeter.burst]), and ends the run.
class RipperSpeedMeter {
  RipperSpeedMeter({
    this.minMs = 3000,
    this.minBytes = 2 * 1024 * 1024,
    this.restartMs = 8000,
    this.maxGapMs = 30000,
  });

  /// The least a run lasts and brings before it is a measurement: the first
  /// seconds of a start hold the wait for the nodes' answers, and one
  /// window is a few connections' luck.
  final int minMs;
  final int minBytes;

  /// A run measured for this long starts over, so that a speed is of the
  /// last seconds, not of the minutes before them.
  final int restartMs;

  /// Longer than this between two windows of a run, and it was not the
  /// connection: an app that stood still (suspended in the background, its
  /// sockets taken away) finishes the window it was on minutes later, and
  /// a megabyte over those minutes would read as a connection that does a
  /// few kbit/s. The run starts over. A connection that truly takes this
  /// long for a window is not measured, and nothing is known of it.
  final int maxGapMs;

  int? _from;
  int _last = 0;
  int _bytes = 0;

  /// A window of [bytes] handed over to its end at [now] (milliseconds, any
  /// clock). [waited]: the player took it before it had all arrived, and
  /// took it without a pause of its own. Returns the run's speed in kbit/s
  /// once it is a measurement, null until then.
  ///
  /// The clock starts as the first such window ends, and only the windows
  /// after it count: of the first, part had arrived before the player
  /// asked. Windows download several at a time, so each one ending in a run
  /// is a window's worth that came in since the one before.
  int? window(int bytes, {required bool waited, required int now}) {
    final from = _from;
    if (!waited) {
      _from = null;
      _bytes = 0;
      return null;
    }
    if (from == null || now - _last > maxGapMs) {
      _from = _last = now;
      _bytes = 0;
      return null;
    }
    _last = now;
    _bytes += bytes;
    final ms = now - from;
    if (ms < minMs || _bytes < minBytes) return null;
    final kbps = _bytes * 8 ~/ ms;
    if (ms >= restartMs) {
      _from = now;
      _bytes = 0;
    }
    return kbps;
  }

  /// What was being measured is let go: the next window starts a run.
  void reset() {
    _from = null;
    _bytes = 0;
  }

  /// The speed, in kbit/s, of one window of [bytes] that took [ms] to
  /// arrive, on its own connections: the least the connection does. Null
  /// for a window too small (under [least]) or too quick to say.
  static int? burst(int bytes, int ms, {int least = 1024 * 1024}) =>
      bytes < least || ms < 10 ? null : bytes * 8 ~/ ms;
}
