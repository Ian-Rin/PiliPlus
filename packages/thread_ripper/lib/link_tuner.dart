// A slow link's settings, set by what the link is doing.
//
// RipperDownloadSettings.slowLink's figures (how long to wait for a first
// byte, when to ask a second node, how many connections) and the app's ten
// minutes of download ahead were set from two passengers' reports of an
// airliner's satellite Wi-Fi. The link the viewer is on may be another
// operator's, another satellite's, or the same one on a worse day, and the
// app cannot be changed in the air. So the figures follow three things the
// proxy sees anyway (BtrRangeProxy feeds them in):
//
// 1. How long a piece waits for its first byte. The timings were set for a
//    slowest tenth of two seconds; they are that tenth's multiples
//    ([_timings]), within bounds. One guard: a timeout that is too short
//    cuts off the slow answers, which then are never measured, and the
//    timeouts would stay short. Where many requests time out while others
//    are answered, the timings do not go below the ones first set, and
//    with still more, half as much again.
// 2. How long the link was gone while pieces were asked for. The download
//    ahead is twice the longest of the last hour and two minutes, ten
//    minutes at least and twenty at most ([bufferSeconds]).
// 3. What the video track downloaded at with 2, 4 and 6 connections
//    ([noteSpeed]). The link's speed moves more from one minute to the next
//    than the connections can change it, so the counts are tried in turn,
//    one measurement each, and compared by their medians; a count replaces
//    the one in use only when its median is a fifth better. Trying is done
//    only while the player is not waiting on the download.
//
// Everything is kept in memory, for as long as the app runs, and shared by
// the proxies of the videos played (each video has its own proxy).

import 'dart:math';

import 'package:thread_ripper/btr/downloader.dart';

/// See the head of this file.
class RipperLinkTuner {
  RipperLinkTuner({DateTime Function()? now, this.onChange})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Told what changed, in a line for a log.
  void Function(String what)? onChange;

  // -------------------------------------------------------------------
  // 1. The timings.

  static const _firstByteKept = 60;
  static const _firstByteFor = Duration(minutes: 10);
  static const _firstByteLeast = 10;

  /// Not more often than this: every change is a new settings object.
  static const _retimeEvery = Duration(seconds: 20);

  final _firstBytes = <({int ms, DateTime at})>[];
  final _timeouts = <DateTime>[];
  DateTime _retimedAt = DateTime(0);

  var _settings = const RipperDownloadSettings.slowLink();

  /// A piece's first byte came [ms] after it was asked for.
  void noteFirstByte(int ms) {
    if (ms < 0) return;
    _firstBytes.add((ms: ms, at: _now()));
    if (_firstBytes.length > _firstByteKept) _firstBytes.removeAt(0);
  }

  /// A piece timed out (no first byte in time, or none for a while midway).
  void noteTimeout() {
    _timeouts.add(_now());
    if (_timeouts.length > _firstByteKept) _timeouts.removeAt(0);
  }

  /// The slowest tenth of the last ten minutes' first bytes, in
  /// milliseconds; null with too few of them.
  int? get firstByteP90 {
    final since = _now().subtract(_firstByteFor);
    final recent = [
      for (final sample in _firstBytes)
        if (sample.at.isAfter(since)) sample.ms,
    ]..sort();
    if (recent.length < _firstByteLeast) return null;
    return recent[((recent.length - 1) * 0.9).round()];
  }

  /// Of the last ten minutes' requests that either got a first byte or
  /// timed out, the share that timed out.
  double get timeoutShare {
    final since = _now().subtract(_firstByteFor);
    final timedOut = _timeouts.where((at) => at.isAfter(since)).length;
    final answered = _firstBytes.where((s) => s.at.isAfter(since)).length;
    return answered < 5 ? 0 : timedOut / (timedOut + answered);
  }

  static int _round(double ms) => (ms / 500).round() * 500;

  /// The timings for a slowest tenth of [p90] ms, each within its bounds;
  /// no lower than [floor] times the ones first set.
  static ({int firstByte, int stall, int hedge, int hedgeFloor, int raceGap})
  _timings(int p90, double floor) {
    int within(double want, int base, int least, int most) =>
        _round(max(want, base * floor)).clamp(least, most);
    return (
      firstByte: within(
        4.0 * p90 + 2000,
        RipperDownloadSettings.slowFirstByteTimeoutMs,
        8000,
        30000,
      ),
      stall: within(
        3.0 * p90 + 3000,
        RipperDownloadSettings.slowStallTimeoutMs,
        8000,
        25000,
      ),
      hedge: within(
        3.0 * p90,
        RipperDownloadSettings.slowHedgeDelayMs,
        3000,
        12000,
      ),
      hedgeFloor: within(
        1.5 * p90,
        RipperDownloadSettings.slowHedgeFloorMs,
        2000,
        6000,
      ),
      raceGap: within(
        1.25 * p90,
        RipperDownloadSettings.slowRaceGapMs,
        1500,
        6000,
      ),
    );
  }

  /// The settings in force: the same object until something changes.
  RipperDownloadSettings get settings {
    final now = _now();
    if (now.difference(_retimedAt) >= _retimeEvery) {
      _retimedAt = now;
      _retime();
    }
    if (_settings.concurrency != _concurrency) {
      _settings = _settings.withConcurrency(_concurrency);
    }
    return _settings;
  }

  void _retime() {
    final p90 = firstByteP90;
    if (p90 == null) return;
    final share = timeoutShare;
    final floor = share > 0.4
        ? 1.5
        : share > 0.15
        ? 1.0
        : 0.0;
    final t = _timings(p90, floor);
    final before = _settings;
    if (t.firstByte == before.firstByteTimeoutMs &&
        t.stall == before.stallTimeoutMs &&
        t.hedge == before.hedgeDelayMs &&
        t.hedgeFloor == before.hedgeFloorMs &&
        t.raceGap == before.raceGapMs) {
      return;
    }
    _settings = RipperDownloadSettings.slowLink(
      concurrency: _concurrency,
      firstByteTimeoutMs: t.firstByte,
      stallTimeoutMs: t.stall,
      hedgeDelayMs: t.hedge,
      hedgeFloorMs: t.hedgeFloor,
      raceGapMs: t.raceGap,
    );
    onChange?.call(
      'time p90=$p90 to=${(share * 100).round()} '
      'fb=${t.firstByte} stall=${t.stall} hedge=${t.hedge}'
      '/${t.hedgeFloor} gap=${t.raceGap}',
    );
  }

  // -------------------------------------------------------------------
  // 2. The download ahead.

  static const leastBufferSeconds = 600;
  static const mostBufferSeconds = 1200;

  /// Shorter than this is a slow moment, not the link gone.
  static const _outageLeast = Duration(seconds: 10);
  static const _outageFor = Duration(minutes: 60);

  final _outages = <({int seconds, DateTime at})>[];
  int _bufferSaid = leastBufferSeconds;

  /// Pieces were asked for and nothing came for [length], until now.
  void noteOutage(Duration length) {
    if (length < _outageLeast) return;
    _outages.add((seconds: length.inSeconds, at: _now()));
    if (_outages.length > 32) _outages.removeAt(0);
    final seconds = bufferSeconds;
    if (seconds != _bufferSaid) {
      _bufferSaid = seconds;
      onChange?.call('buffer out=${length.inSeconds} secs=$seconds');
    }
  }

  /// The longest the link was gone in the last hour, in seconds; 0 if it
  /// was not.
  int get longestOutageSeconds {
    final since = _now().subtract(_outageFor);
    var longest = 0;
    for (final outage in _outages) {
      if (outage.at.isAfter(since)) longest = max(longest, outage.seconds);
    }
    return longest;
  }

  /// How far ahead the player is to download: twice the last hour's
  /// longest outage and two minutes, to the minute, within ten to twenty.
  int get bufferSeconds {
    final longest = longestOutageSeconds;
    if (longest == 0) return leastBufferSeconds;
    final want = ((2 * longest + 120) / 60).ceil() * 60;
    return want.clamp(leastBufferSeconds, mostBufferSeconds);
  }

  // -------------------------------------------------------------------
  // 3. The connections.

  /// The counts tried, the one first set first.
  static const counts = [4, 2, 6];
  static const _speedKept = 6;
  static const _speedFor = Duration(minutes: 20);
  static const _speedLeast = 3;

  /// A count replaces the one in use when its median is this much better.
  static const _better = 1.2;

  final _speeds = <int, List<({int kbps, DateTime at})>>{
    for (final count in counts) count: [],
  };
  int _concurrency = counts.first;

  /// The connections in use.
  int get concurrency => _concurrency;

  List<int> _recent(int count) {
    final since = _now().subtract(_speedFor);
    return [
      for (final sample in _speeds[count]!)
        if (sample.at.isAfter(since)) sample.kbps,
    ];
  }

  /// The median speed measured with [count] connections; null with too
  /// few measurements in the last twenty minutes.
  int? medianWith(int count) {
    if (!_speeds.containsKey(count)) return null;
    final recent = _recent(count)..sort();
    if (recent.length < _speedLeast) return null;
    final mid = recent.length ~/ 2;
    return recent.length.isOdd
        ? recent[mid]
        : (recent[mid - 1] + recent[mid]) ~/ 2;
  }

  /// A speed of the video track measured while the player took all that
  /// came (BtrRangeProxy.onSpeed, sustained), with the connections in use.
  /// [mayExplore]: the player is not waiting on the download, so a count
  /// that may be worse can be tried. The count for what comes next is then
  /// [concurrency].
  void noteSpeed(int kbps, {required bool mayExplore}) {
    if (kbps <= 0) return;
    final samples = _speeds[_concurrency];
    if (samples == null) return;
    samples.add((kbps: kbps, at: _now()));
    if (samples.length > _speedKept) samples.removeAt(0);
    final next = _pick(mayExplore);
    if (next == _concurrency) return;
    final from = _concurrency;
    _concurrency = next;
    onChange?.call(
      'conn $from>$next ${[
        for (final count in counts) '$count=${medianWith(count) ?? '?'}',
      ].join(' ')}',
    );
  }

  int _pick(bool mayExplore) {
    if (mayExplore) {
      // The count measured least, of those not measured enough: in turn,
      // so that each is measured over the same minutes.
      int? least;
      var fewest = _speedLeast;
      for (final count in counts) {
        final have = _recent(count).length;
        if (have < fewest) {
          fewest = have;
          least = count;
        }
      }
      if (least != null) return least;
    }
    // The best of those measured, if it is better enough than this one.
    int? best;
    var bestSpeed = 0;
    for (final count in counts) {
      final speed = medianWith(count);
      if (speed != null && speed > bestSpeed) {
        bestSpeed = speed;
        best = count;
      }
    }
    if (best == null) return _concurrency;
    final mine = medianWith(_concurrency);
    // Not measured (it was being tried when trying had to stop): the best.
    if (mine == null) return best;
    return bestSpeed >= mine * _better ? best : _concurrency;
  }

  // -------------------------------------------------------------------

  /// The figures in force, for the viewer to read.
  String describe() {
    final s = settings;
    final p90 = firstByteP90;
    return [
      '首字节九成 ${p90 == null ? '还不知道' : '$p90 毫秒'}'
          '（超时占 ${(timeoutShare * 100).round()}%）',
      '首字节超时 ${s.firstByteTimeoutMs / 1000} 秒，'
          '中途无数据 ${s.stallTimeoutMs / 1000} 秒，'
          '要第二份 ${s.hedgeFloorMs / 1000} 到 ${s.hedgeDelayMs / 1000} 秒，'
          '起播换节点 ${s.raceGapMs / 1000} 秒',
      '连接数 $_concurrency（${[
        for (final count in counts) '$count 条 ${medianWith(count) ?? '?'}',
      ].join('，')} kbit/s）',
      '提前缓冲 ${bufferSeconds ~/ 60} 分钟'
          '（一小时内最长断网 $longestOutageSeconds 秒）',
    ].join('\n');
  }
}
