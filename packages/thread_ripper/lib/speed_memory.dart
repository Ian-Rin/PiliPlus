// The download speed of the video track known from the last videos, and the
// quality a video starts on by it.
//
// After Bilibili-thread-ripper's automatic quality (page-hook.js,
// driveAutoQuality), which in a browser changes the quality as a video
// plays. In the app a change of quality opens the video again (a second or
// two of spinner), so the speed is used once, as a video is opened: where
// the connection has just shown that it does not carry the quality set, the
// video starts a step or more below it instead of waiting on the download at
// every scene. What is taken over from upstream:
// - A quality is carried when its bitrate, half as much again ([headroom]),
//   is within the speed.
// - Two speeds are told apart (RipperSpeedMeter). One measured while the
//   player waited on the download is what the connection does: it sets the
//   speed known, up or down. One window's own speed is only the least it
//   does: it may raise the speed known, never lower it, and against a
//   measurement made lately it counts only from twice as much
//   ([burstBeyond]): a second of downloads is not what a connection keeps up.
//
// What is not: upstream keeps a speed for a week, since it looks again every
// second and puts a quality right within seconds. A speed that was low hours
// ago would here start every video low until one had measured again, so it
// is forgotten after [validFor].

/// See the head of this file. [load] and [save] keep the speed across a
/// restart (one value for Wi-Fi, one for the mobile network); without them
/// it is only remembered while the app runs.
class RipperSpeedMemory {
  RipperSpeedMemory({this.load, this.save});

  final String? Function(bool wifi)? load;
  final void Function(bool wifi, String value)? save;

  static const headroom = 1.5;
  static const burstBeyond = 2;
  static const validFor = Duration(minutes: 30);

  /// How long a measurement made while the player waited outweighs one
  /// window's speed that is not [burstBeyond] times it.
  static const _provenFor = Duration(minutes: 10);

  /// Whether the device is on Wi-Fi: a speed is of one or of the other.
  bool onWifi = true;

  final _known = <bool, ({int kbps, DateTime at})?>{};
  final _proven = <bool, ({int kbps, DateTime at})>{};
  final _savedAt = <bool, DateTime>{};

  ({int kbps, DateTime at})? _kept(bool wifi) {
    if (_known.containsKey(wifi)) return _known[wifi];
    ({int kbps, DateTime at})? found;
    try {
      final parts = (load?.call(wifi) ?? '').split(':');
      final kbps = int.tryParse(parts.first);
      final at = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (kbps != null && kbps > 0 && at != null) {
        found = (kbps: kbps, at: DateTime.fromMillisecondsSinceEpoch(at));
      }
    } catch (_) {}
    return _known[wifi] = found;
  }

  /// The speed known for the network the device is on, in kbit/s; null if
  /// none was measured within [validFor].
  int? known({DateTime? now}) {
    final kept = _kept(onWifi);
    if (kept == null) return null;
    final age = (now ?? DateTime.now()).difference(kept.at);
    return age.isNegative || age > validFor ? null : kept.kbps;
  }

  /// A speed the proxy measured (BtrRangeProxy.onSpeed).
  void note(int kbps, {required bool sustained, DateTime? now}) {
    if (kbps <= 0) return;
    final at = now ?? DateTime.now();
    final wifi = onWifi;
    if (sustained) {
      _proven[wifi] = (kbps: kbps, at: at);
    } else {
      final before = known(now: at);
      if (before != null && kbps <= before) return;
      final proven = _proven[wifi];
      if (proven != null &&
          at.difference(proven.at) < _provenFor &&
          kbps < proven.kbps * burstBeyond) {
        return;
      }
    }
    final before = _kept(wifi);
    _known[wifi] = (kbps: kbps, at: at);
    // Kept across a restart, without a write for every window: when it has
    // moved by a tenth, or once in a few minutes.
    final saved = _savedAt[wifi];
    if (before == null ||
        saved == null ||
        (kbps - before.kbps).abs() * 10 > before.kbps ||
        at.difference(saved) > const Duration(minutes: 5)) {
      _savedAt[wifi] = at;
      try {
        save?.call(wifi, '$kbps:${at.millisecondsSinceEpoch}');
      } catch (_) {}
    }
  }

  /// The quality to start on. [offered]: the stream of the quality set
  /// first, then those of the qualities below it, best first, each with its
  /// bitrate in bits a second (0 if it states none). The first that [kbps]
  /// carries with [headroom]; the lowest if it carries none; the quality
  /// set if no speed is known.
  static int pick(List<({int quality, int bandwidth})> offered, int? kbps) {
    assert(offered.isNotEmpty);
    if (kbps == null) return offered.first.quality;
    for (final stream in offered) {
      if (stream.bandwidth <= 0 || stream.bandwidth * headroom <= kbps * 1000) {
        return stream.quality;
      }
    }
    return offered.last.quality;
  }
}
