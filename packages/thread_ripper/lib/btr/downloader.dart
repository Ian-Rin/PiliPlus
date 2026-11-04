// Port of Bilibili-thread-ripper src/idm-downloader.js (2026.11.3.1), MIT.
// See docs/licenses/bilibili-thread-ripper.txt.
//
// Kept line for line with upstream: names, order, constants and comments
// follow the JavaScript, so an upstream diff maps onto this file. What the
// browser provides comes from btr/errors.dart (DOMException, AbortController,
// Promise.any) and btr/fetch.dart (fetch and its body reader); the clock is
// injected, like upstream's performance.now(), so tests can run on virtual
// time. The auto-concurrency controller (createAutoConcurrency) is
// auto_concurrency.dart, checked against upstream by its own fixtures.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:thread_ripper/auto_concurrency.dart';
import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/btr/fetch.dart';
import 'package:thread_ripper/btr/range_core.dart';
import 'package:thread_ripper/btr/resolver.dart';

const _pieceRounds = 3;
const _pieceRetryWindowMs = 25000;
// The pause before a piece's next round of addresses: half a second, doubling, at most two.
int roundPause(int round) => min(2000, 500 * (1 << (round - 1)));
// Below this a resumed request saves less than its own round trip costs.
const _resumeMinBytes = 32 * 1024;
// Hedging a piece with a playback deadline (see hedgeDue): a first copy projected to finish
// this long before the deadline gets no copy yet; one receiving at least HEDGE_PACE of the
// usual connection speed is on pace; a copy's node measured HEDGE_FASTER times faster than the
// first copy is receiving is worth a copy anyway.
const _hedgeSlackMs = 1500;
const _hedgePace = 0.6;
const _hedgeFaster = 1.5;
// Queue classes, served in this order: the startup probe and init/index, then startup
// pieces, then everything else. A class never waits behind a lower one.
const queueCritical = 0, queueStartup = 1, queueOrdinary = 2;
// Priority an ordinary request with a playback deadline gains per millisecond of waiting:
// 20 (a hedge copy's boost) in 0.9 s.
const _queueAgingPerMs = 20 / 900;
// A shorter transfer is mostly round trip. The tail of a resumed piece can be a few KiB,
// and counting it would mark down the very node that came to the rescue.
const _speedSampleMinBytes = 48 * 1024;

const _infinity = double.infinity;

/// JavaScript's Math.round (halves round up, also for negative numbers).
int _jsRound(double value) => (value + 0.5).floor();

Duration _ms(num ms) => Duration(microseconds: (ms * 1000).round());

/// The settings the downloader reads (upstream normalizeSettings, the
/// download part).
class RipperDownloadSettings {
  const RipperDownloadSettings({
    this.concurrency = 8,
    this.autoConcurrency = false,
    this.minChunkBytes = 64 * 1024,
    this.firstByteTimeoutMs = 5500,
    this.stallTimeoutMs = 4000,
    this.attemptTimeoutMs = 15000,
    this.hedgeDelayMs = 900,
  });

  static const allowedConcurrency = [4, 8, 16, 32, 64, 128];

  final int concurrency;

  /// 自动线程数: the thread count is the controller's.
  final bool autoConcurrency;
  final int minChunkBytes;
  final int firstByteTimeoutMs;
  final int stallTimeoutMs;
  final int attemptTimeoutMs;
  final int hedgeDelayMs;

  /// normalizeSettings: a thread count the settings do not offer becomes 8;
  /// the timings are upstream's constants.
  RipperDownloadSettings normalized() => RipperDownloadSettings(
    concurrency: allowedConcurrency.contains(concurrency) ? concurrency : 8,
    autoConcurrency: autoConcurrency,
  );

  RipperDownloadSettings withConcurrency(int concurrency) =>
      RipperDownloadSettings(
        concurrency: concurrency,
        autoConcurrency: autoConcurrency,
        minChunkBytes: minChunkBytes,
        firstByteTimeoutMs: firstByteTimeoutMs,
        stallTimeoutMs: stallTimeoutMs,
        attemptTimeoutMs: attemptTimeoutMs,
        hedgeDelayMs: hedgeDelayMs,
      );
}

typedef RipperRelease = void Function();

class _QueueEntry {
  _QueueEntry({
    required this.completer,
    required this.signal,
    required this.priority,
    required this.deadlineAt,
    required this.deadline,
    required this.queueClass,
    required this.ages,
    required this.queuedAt,
    required this.sequence,
  });

  final Completer<RipperRelease> completer;
  final RipperAbortSignal? signal;
  bool released = false;
  final double priority;
  final double deadlineAt;
  final double Function()? deadline;
  final int queueClass;
  final bool ages;
  final double queuedAt;
  final int sequence;
  late final void Function() cancel;
}

class RipperSemaphore {
  RipperSemaphore(this.limit, this._now);

  final double Function() _now;
  int limit;
  int active = 0;
  final queue = <_QueueEntry>[];
  int _sequence = 0;
  void Function(int active, int limit, int queued)? onChange;

  void setLimit(num limit) {
    final requested = limit.isFinite ? limit.truncate() : 0;
    this.limit = max(1, min(512, requested == 0 ? 1 : requested));
    drain();
  }

  void drain() {
    try {
      _drainQueue();
    } finally {
      onChange?.call(active, limit, queue.length);
    }
  }

  void _drainQueue() {
    while (active < limit && queue.isNotEmpty) {
      final now = _now();
      double urgency(_QueueEntry entry) {
        // Read again at every pass: the player's deadline moves with the playhead and the
        // playback rate, and a queued piece may have become due while it waited.
        final deadlineAt = entry.deadline != null
            ? entry.deadline!()
            : entry.deadlineAt;
        if (!deadlineAt.isFinite) return 0;
        final remaining = deadlineAt - now;
        if (remaining <= 0) return 12;
        if (remaining <= 750) return 9;
        if (remaining <= 2000) return 6;
        return 0;
      }

      // A bounded, recomputed boost prevents overdue primaries from sitting behind
      // prefetch work without turning the queue back into strict deadline ordering. A
      // request with a deadline also gains priority while it waits, so a piece queued long
      // ago is not passed over again and again by newer ones of a slightly higher priority;
      // requests without one (compatibility mode, the desktop client) keep the fixed order.
      // Sorting inside the class keeps the startup probe, init and index, and then the
      // startup pieces, ahead of ordinary media whatever the boosts add up to.
      double rank(_QueueEntry entry) =>
          entry.priority +
          urgency(entry) +
          (entry.ages ? (now - entry.queuedAt) * _queueAgingPerMs : 0);
      queue.sort((a, b) {
        final byClass = a.queueClass - b.queueClass;
        if (byClass != 0) return byClass;
        final byRank = rank(b) - rank(a);
        if (byRank != 0) return byRank < 0 ? -1 : 1;
        return a.sequence - b.sequence;
      });
      final entry = queue.removeAt(0);
      entry.signal?.removeListener(entry.cancel);
      if (entry.signal?.aborted ?? false) {
        entry.completer.completeError(abortError(entry.signal!.reason));
        continue;
      }
      active += 1;
      entry.completer.complete(() {
        if (entry.released) return;
        entry.released = true;
        active = max(0, active - 1);
        drain();
      });
    }
  }

  // deadline: a function giving the clock time playback needs this request, or null; the
  // fixed deadlineAt is what callers without one pass.
  Future<RipperRelease> acquire(
    RipperAbortSignal? signal, [
    double priority = 0,
    double deadlineAt = _infinity,
    int queueClass = queueCritical,
    bool ages = false,
    double Function()? deadline,
  ]) {
    if (signal?.aborted ?? false) {
      return Future.error(abortError(signal!.reason));
    }
    final completer = Completer<RipperRelease>();
    final entry = _QueueEntry(
      completer: completer,
      signal: signal,
      priority: priority.isNaN ? 0 : priority,
      deadlineAt: deadlineAt.isFinite ? deadlineAt : _infinity,
      deadline: deadline,
      queueClass: queueClass,
      ages: ages,
      queuedAt: _now(),
      sequence: _sequence++,
    );
    entry.cancel = () {
      final index = queue.indexOf(entry);
      if (index < 0) return;
      queue.removeAt(index);
      signal!.removeListener(entry.cancel);
      completer.completeError(abortError(signal.reason));
    };
    signal?.addListener(entry.cancel);
    queue.add(entry);
    drain();
    return completer.future;
  }
}

/// What a range's pieces arrive through: bytes in file order, the piece they
/// belong to, and the file's total length (null when the server did not say).
typedef RipperOrderedChunk = FutureOr<void> Function(
  Uint8List bytes,
  RipperPiece piece,
  int? total,
);

/// downloadRange's options.
class RipperRangeOptions {
  const RipperRangeOptions({
    this.signal,
    this.kind,
    this.startup = false,
    this.parallel = true,
    this.maxConcurrency,
    this.priority,
    this.deadlineAt,
    this.deadlineAtFn,
    this.deadlineMs,
    this.deadlineMsFn,
    this.onOrderedChunk,
    this.onStartupScheduled,
  });

  final RipperAbortSignal? signal;

  /// "meta" (init and index), "video", "audio", "media".
  final String? kind;
  final bool startup;
  final bool parallel;
  final num? maxConcurrency;
  final num? priority;

  // When playback needs the range: a clock time (deadlineAt) or the time left
  // (deadlineMs), either fixed or read again at every check.
  final double? deadlineAt;
  final double Function()? deadlineAtFn;
  final double? deadlineMs;
  final double Function()? deadlineMsFn;
  final RipperOrderedChunk? onOrderedChunk;
  final void Function()? onStartupScheduled;
}

class RipperRangeResult {
  const RipperRangeResult({
    required this.bytes,
    required this.byteLength,
    required this.pieceCount,
    required this.streamed,
    required this.total,
    required this.hosts,
  });

  /// The whole range, or null when it went to onOrderedChunk.
  final Uint8List? bytes;

  /// null for a "meta" range, as upstream leaves it out there.
  final int? byteLength;
  final int pieceCount;
  final bool? streamed;
  final int? total;
  final List<String> hosts;
}

class _Result {
  const _Result(this.bytes, this.total, this.url);

  final Uint8List bytes;
  final int? total;
  final Uri url;
}

class _Recorder {
  int bytes = 0;
  final chunks = <Uint8List>[];
}

class _Prefix {
  const _Prefix(this.bytes, this.chunks);

  final int bytes;
  final List<Uint8List> chunks;
}

class _Plan {
  const _Plan(this.recorder, this.part);

  final _Recorder recorder;
  final RipperPiece part;
}

/// A copy of a piece once it holds a connection.
class _Context {
  _Context(this.base, this.recorder, this.startedAt, this.length)
    : seenAt = startedAt;

  final _Prefix? base;
  final _Recorder recorder;
  final double startedAt;
  int seenBytes = 0;
  double seenAt;
  final int length;
}

class _EarlyHedge {
  _EarlyHedge(int limit)
    : progressRemaining = max(0, limit),
      // At least one per range, even where no connection is held back (a single-piece
      // download): one request is much cheaper than waiting out a timeout.
      staleRemaining = max(1, limit);

  int progressRemaining;
  int staleRemaining;

  bool claimProgress() {
    if (progressRemaining <= 0) return false;
    progressRemaining -= 1;
    return true;
  }

  bool claimStale() {
    if (staleRemaining <= 0) return false;
    staleRemaining -= 1;
    return true;
  }
}

class _TrialState {
  int waited = 0;
  int cursor = 0;
}

// Hands the finished pieces to onOrderedChunk in order: each one as soon as every piece
// before it has been handed over. done() waits for what has been handed over so far.
class _OrderedDelivery {
  _OrderedDelivery(this.pieces, this.onOrderedChunk)
    : ordered = List.filled(pieces.length, null);

  final List<RipperPiece> pieces;
  final RipperOrderedChunk? onOrderedChunk;
  final List<_Result?> ordered;
  int next = 0;
  Future<void> operation = Future.value();

  Future<void> add(int index, _Result result) {
    ordered[index] = result;
    operation = operation.then((_) async {
      while (next < ordered.length && ordered[next] != null) {
        final item = ordered[next]!;
        ordered[next] = null;
        await onOrderedChunk!(item.bytes, pieces[next], item.total);
        next += 1;
      }
    });
    return operation;
  }

  Future<void> done() => operation;
}

/// Upstream `createDownloader`.
class RipperDownloader {
  RipperDownloader({
    required this._fetch,
    required this._getSettings,
    RipperAutoConcurrency? autoConcurrency,
    double Function()? now,
    Object? Function(Map<String, Object?> event)? onTransfer,
  }) : _now = now ?? _stopwatchNow(),
       _onTransfer = onTransfer ?? ((_) => null) {
    _autoConcurrency = autoConcurrency ?? RipperAutoConcurrency();
    _semaphore = RipperSemaphore(config().concurrency, _now);
    // Every downloader follows the controller's count at once.
    _unsubscribe = _autoConcurrency.subscribe(applySettings);
    _semaphore.onChange = (active, limit, queued) {
      if (config().autoConcurrency) {
        _autoConcurrency.demand(active, limit, queued);
      }
    };
  }

  static double Function() _stopwatchNow() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds / 1000;
  }

  final RipperFetch _fetch;
  final RipperDownloadSettings Function() _getSettings;
  final double Function() _now;
  final Object? Function(Map<String, Object?> event) _onTransfer;
  late final RipperAutoConcurrency _autoConcurrency;
  late final RipperSemaphore _semaphore;
  late final void Function() _unsubscribe;

  // getSettings returns a new object whenever something changes (the userscript's page
  // does), so the reference tells whether the previous normalization is still valid.
  RipperDownloadSettings? _rawSettings;
  RipperDownloadSettings? _normalizedSettings;
  RipperDownloadSettings? _autoView;

  RipperDownloadSettings config() {
    final raw = _getSettings();
    if (!identical(raw, _rawSettings) || _normalizedSettings == null) {
      _rawSettings = raw;
      _normalizedSettings = raw.normalized();
      _autoView = null;
    }
    final normalized = _normalizedSettings!;
    if (!normalized.autoConcurrency) return normalized;
    // In the automatic mode the thread count is the controller's, everything else the viewer's.
    final threads = _autoConcurrency.threads;
    if (_autoView == null || _autoView!.concurrency != threads) {
      _autoView = normalized.withConcurrency(threads);
    }
    return _autoView!;
  }

  void applySettings() => _semaphore.setLimit(config().concurrency);

  int get concurrency => _semaphore.limit;

  /// Stops following the auto-concurrency controller.
  void dispose() => _unsubscribe();

  // What one connection typically delivers here and how long a sub-chunk typically
  // takes. Sub-chunk sizing and the hedge delay follow these measurements.
  double _connectionBps = 0;
  double _pieceMs = 0;

  void _recordMeter(int bytes, double elapsedMs) {
    if (bytes < _speedSampleMinBytes || elapsedMs <= 0) return;
    final bps = bytes * 1000 / elapsedMs;
    _connectionBps = _connectionBps != 0
        ? _connectionBps * 0.7 + bps * 0.3
        : bps;
    _pieceMs = _pieceMs != 0 ? _pieceMs * 0.7 + elapsedMs * 0.3 : elapsedMs;
  }

  // A sub-chunk should keep its connection busy for a good part of a second, otherwise
  // request round trips dominate on high-latency routes. 64 KiB stays the floor while
  // the speed is still unknown, and a range still splits into at least one piece per
  // node: the total bandwidth only grows by spreading over hosts, and the hedges
  // against a stalling one need more than a single request to work with.
  num _adaptiveMinChunk(
    RipperDownloadSettings settings,
    int rangeLength,
    int pieceLimit, [
    int hostCount = 4,
  ]) {
    if (_connectionBps == 0) return settings.minChunkBytes;
    final target = (_connectionBps * 0.6 / (64 * 1024)).floor() * 64 * 1024;
    final spread = (rangeLength / max(1, min(max(4, hostCount), pieceLimit)))
        .ceil();
    return max(settings.minChunkBytes, min(1024 * 1024, min(target, spread)));
  }

  // A second copy starts once a piece takes clearly longer than pieces have been
  // taking, instead of always waiting the full fixed delay.
  num _hedgeDelayMs(RipperDownloadSettings settings) => _pieceMs != 0
      ? max(250, min(settings.hedgeDelayMs, _jsRound(_pieceMs * 1.5)))
      : settings.hedgeDelayMs;

  // Whether the second copy of a piece with a playback deadline should start now. Checked
  // every 50 ms once the first copy holds a connection (a copy of a request still queued
  // would only queue as well, and with its higher priority take the connection meant for
  // it). first: the first copy (when it started, bytes received, bytes asked for); the delay
  // counts from its start. copyBps: the measured speed of the copy's node, 0 when unknown.
  // - No data yet, or nothing new for a whole delay (stopped): copy.
  // - A deadline it meets with time to spare at its speed so far: no copy yet, the bandwidth
  //   goes to pieces needed sooner.
  // - The copy's node known to be clearly faster (HEDGE_FASTER times): copy.
  // - Slower than connections usually are, or no usual speed measured yet: copy.
  // - On pace: a copy on a node not known to be HEDGE_FASTER times faster only takes the
  //   next piece's connection and bandwidth; one on a node not measured yet is tried, as
  //   the chance of a faster one. A piece that will miss its deadline even so may spend one
  //   of the range's rescue slots on that node anyway: its measurement can be stale (a node
  //   that was slow a minute ago may have recovered), and waiting for the request to time
  //   out costs far more.
  bool _hedgeDue(
    _Context first,
    num delayMs,
    double deadlineAt,
    double copyBps,
    _EarlyHedge? rescue,
  ) {
    final now = _now(), ran = now - first.startedAt;
    final got = first.recorder.bytes;
    if (got != first.seenBytes) {
      first
        ..seenBytes = got
        ..seenAt = now;
    }
    if (ran < delayMs) return false;
    if (got == 0 || now - first.seenAt >= delayMs) return true;
    final rate = got * 1000 / ran;
    if (now + max(0, first.length - got) * 1000 / rate <=
        deadlineAt - _hedgeSlackMs) {
      return false;
    }
    if (copyBps > rate * _hedgeFaster) return true;
    if (!(_connectionBps > 0) || rate < _connectionBps * _hedgePace) {
      return true;
    }
    if (!(copyBps > 0)) return true;
    return now + max(0, first.length - got) * 1000 / rate > deadlineAt &&
        (rescue?.claimStale() ?? false);
  }

  // When playback needs a range, as a clock time; Infinity when the caller did not say.
  // options.deadlineAt is that time, options.deadlineMs the time left; either can be a
  // function, read again at every check, so a new playback rate or position also moves the
  // deadline of pieces already on their way.
  double Function() _deadlineOf(RipperRangeOptions options) {
    double read(double? value, bool relative) {
      if (value == null || !value.isFinite) return _infinity;
      return relative ? _now() + max(0, value) : value;
    }

    double Function() live(double Function() value, bool relative) => () {
      try {
        return read(value(), relative);
      } catch (_) {
        return _infinity;
      }
    };
    if (options.deadlineAtFn != null) return live(options.deadlineAtFn!, false);
    if (options.deadlineAt != null && options.deadlineAt!.isFinite) {
      final fixed = options.deadlineAt!;
      return () => fixed;
    }
    if (options.deadlineMsFn != null) return live(options.deadlineMsFn!, true);
    final fixed = read(options.deadlineMs, true);
    return () => fixed;
  }

  Future<Uint8List> _readBody(
    RipperResponse response,
    RipperAbortController controller,
    Object? transferId,
    RipperDownloadSettings settings,
    _Recorder received, [
    Object? Function(Map<String, Object?> event)? report,
  ]) async {
    report ??= _onTransfer;
    final reader = response.body;
    // Do not rely on fetch implementations to unblock read() after abort. A
    // pending reader must release its concurrency slot before a quality change.
    void cancelReader() {
      unawaited(
        reader.cancel(controller.signal.reason).catchError((Object _) {}),
      );
    }

    controller.signal.addListener(cancelReader);
    if (controller.signal.aborted) cancelReader();
    final chunks = <Uint8List>[];
    var total = 0;
    Timer? stallTimer;
    void armStall() {
      stallTimer?.cancel();
      stallTimer = Timer(
        _ms(settings.stallTimeoutMs),
        () => controller.abort(RipperError.timeout('CDN 子块停止传输')),
      );
    }

    armStall();
    try {
      while (true) {
        final value = await reader.read();
        if (controller.signal.aborted) {
          throw abortError(controller.signal.reason);
        }
        if (value == null) break;
        armStall();
        chunks.add(value);
        total += value.length;
        received.bytes += value.length;
        // The recorder keeps what a failed attempt already received, so a retry or a
        // hedge copy can ask only for the missing tail.
        received.chunks.add(value);
        if (settings.autoConcurrency) _autoConcurrency.activity();
        report({'phase': 'progress', 'id': transferId, 'bytes': value.length});
      }
    } finally {
      stallTimer?.cancel();
      controller.signal.removeListener(cancelReader);
    }
    return concatChunks(chunks, total);
  }

  // begin: called once the request has its connection slot, and returns what to ask for.
  // A copy that waited in the queue resumes from what the first copy has received by then,
  // not from what it had when the copy was queued.
  Future<_Result> _attempt(
    RipperPiece piece,
    Uri url,
    RipperAbortSignal? signal,
    String kind,
    RipperResolver resolver, [
    num priority = 0,
    _Plan Function()? begin,
    double Function()? deadline,
    void Function(Map<String, Object?> event)? observeProgress,
    int queueClass = queueCritical,
  ]) async {
    final settings = config();
    final deadlineAt = deadline != null ? deadline() : _infinity;
    final release = await _semaphore.acquire(
      signal,
      priority.toDouble(),
      deadlineAt,
      queueClass,
      queueClass == queueOrdinary && deadlineAt.isFinite,
      deadline,
    );
    var received = _Recorder();
    if (begin != null) {
      try {
        final plan = begin();
        piece = plan.part;
        received = plan.recorder;
      } catch (_) {
        release();
        rethrow;
      }
    }
    final controller = RipperAbortController();
    void cancel() => controller.abort(abortError(signal?.reason));
    if (signal?.aborted ?? false) {
      cancel();
    } else {
      signal?.addListener(cancel);
    }
    final firstByteTimer = Timer(
      _ms(settings.firstByteTimeoutMs),
      () => controller.abort(RipperError.timeout('CDN 首字节超时')),
    );
    final totalTimer = Timer(
      _ms(settings.attemptTimeoutMs),
      () => controller.abort(RipperError.timeout('CDN 子块总耗时超限')),
    );
    final startedAt = _now();
    Object? report(Map<String, Object?> event) {
      final elapsedMs = max(1.0, _now() - startedAt);
      final bps = received.bytes * 1000 / elapsedMs;
      final remaining = max(0, piece.length - received.bytes);
      final payload = {
        ...event,
        'receivedBytes': received.bytes,
        'totalBytes': piece.length,
        'bps': bps,
        'etaMs': bps > 0 ? _jsRound(remaining * 1000 / bps) : null,
      };
      observeProgress?.call({...payload, 'elapsedMs': elapsedMs});
      return _onTransfer(payload);
    }

    final transferId = report({
      'phase': 'start',
      'kind': kind,
      'totalBytes': piece.length,
      'url': url,
      'deadlineAt': deadlineAt.isFinite ? deadlineAt : null,
    });
    try {
      final response = await _fetch(
        url,
        RipperRequest(
          start: piece.start,
          end: piece.end,
          signal: controller.signal,
          highPriority: priority >= 100,
        ),
      );
      firstByteTimer.cancel();
      final contentRange = parseContentRange(response.header('content-range'));
      if (response.status != 206 ||
          contentRange == null ||
          contentRange.start != piece.start ||
          contentRange.end != piece.end) {
        // The status tells a refused signed address (4xx) apart from a node that is down.
        throw RipperError(
          'Range 校验失败：HTTP ${response.status}',
          status: response.status,
        );
      }
      final bytes = await _readBody(
        response,
        controller,
        transferId,
        settings,
        received,
        report,
      );
      if (bytes.length != piece.length) {
        throw RipperError('子块长度不符：${bytes.length}/${piece.length}');
      }
      final elapsedMs = max(1.0, _now() - startedAt);
      _recordMeter(bytes.length, elapsedMs);
      // The node answered either way; only a large enough transfer says how fast it is.
      resolver.success(
        url,
        bytes.length >= _speedSampleMinBytes
            ? bytes.length * 1000 / elapsedMs
            : 0,
      );
      report({'phase': 'done', 'id': transferId});
      return _Result(bytes, contentRange.total, url);
    } catch (error) {
      final canceled = errorName(error) == 'AbortError';
      // A copy that lost the race was cut off, not broken, and what it had received by then
      // is a measurement of its node. Without it a slow node is never measured at all: its
      // pieces are always finished by a faster copy first, and an unmeasured node only ever
      // gets trial pieces.
      if (canceled && received.bytes >= _speedSampleMinBytes) {
        resolver.sample(
          url,
          received.bytes * 1000 / max(1.0, _now() - startedAt),
        );
      }
      // Received bytes tell a dead node (0 KiB) apart from a transfer that stalled midway.
      resolver.failure(url, error, received.bytes);
      if (settings.autoConcurrency) {
        final status = errorStatus(error);
        if (status == 412 || status == 429) {
          _autoConcurrency.pushback();
        } else if (!canceled &&
            errorName(error) == 'TimeoutError' &&
            received.bytes == 0) {
          _autoConcurrency.slow();
        }
      }
      report({
        'phase': canceled ? 'cancel' : 'error',
        'id': transferId,
        'error': error,
      });
      rethrow;
    } finally {
      firstByteTimer.cancel();
      totalTimer.cancel();
      // Invalid headers can reject before readBody obtains a reader. Stop that
      // response too, otherwise it keeps downloading after releasing the slot.
      controller.abort();
      signal?.removeListener(cancel);
      release();
    }
  }

  Future<void> _pause(int delayMs, RipperAbortSignal? signal) {
    final completer = Completer<void>();
    late final Timer timer;
    late final void Function() canceled;
    void done() {
      signal?.removeListener(canceled);
      completer.complete();
    }

    canceled = () {
      timer.cancel();
      completer.completeError(abortError(signal!.reason));
    };
    timer = Timer(_ms(delayMs), done);
    if (signal?.aborted ?? false) {
      canceled();
    } else {
      signal?.addListener(canceled);
    }
    return completer.future;
  }

  /// Array.prototype.sort is stable; Dart's List.sort is not.
  static List<T> _stableSorted<T>(
    List<T> list,
    int Function(T a, T b) compare,
  ) {
    final indexed = List.generate(list.length, (i) => i)
      ..sort((a, b) {
        final order = compare(list[a], list[b]);
        return order != 0 ? order : a - b;
      });
    return [for (final i in indexed) list[i]];
  }

  static int _sign(double value) => value < 0 ? -1 : (value > 0 ? 1 : 0);

  List<Uri> _pieceCandidates(
    RipperPiece piece,
    RipperResolver resolver,
    List<Uri>? preferredUrls,
    int round,
  ) {
    final preferred = preferredUrls ?? const <Uri>[];
    // The first preferred address is the node this piece was assigned to by speed;
    // only a retry round moves past it.
    final preferredOffset = preferred.isNotEmpty ? round % preferred.length : 0;
    final rotatedPreferred = [
      ...preferred.sublist(preferredOffset),
      ...preferred.sublist(0, preferredOffset),
    ];
    final rescue = resolver
        .rescueCandidates()
        .where((url) => !rotatedPreferred.contains(url))
        .toList();
    // The copies after the first go to the fastest known nodes, wherever they were
    // listed: a hedge that lands on the slowest node saves nothing.
    final rest = _stableSorted(
      [...rotatedPreferred.skip(1), ...rescue],
      (left, right) => _sign(resolver.speed(right) - resolver.speed(left)),
    );
    final candidates = rotatedPreferred.isNotEmpty
        ? [rotatedPreferred.first, ...rest]
        : rest;
    for (final url in resolver.ordered(piece.index)) {
      if (!candidates.contains(url)) candidates.add(url);
    }
    return candidates;
  }

  /// [startupMode]: false, true (a start's pieces) or "probe" (its first
  /// request, raced on several nodes at once).
  Future<_Result> _downloadPiece(
    RipperPiece piece,
    RipperResolver resolver,
    RipperAbortSignal? signal,
    String kind,
    List<Uri>? preferredUrls, [
    Object startupMode = false,
    num priority = 0,
    double Function()? deadline,
    _EarlyHedge? earlyHedge,
  ]) async {
    final hasDeadline = deadline != null && deadline().isFinite;
    double deadlineNow() => deadline != null ? deadline() : _infinity;
    final settings = config();
    bool allowed(Uri url) => resolver.allows(url);
    final startup = startupMode == true || startupMode == 'probe';
    final probe = startupMode == 'probe';
    final startedAt = _now();
    Object? lastError;

    // The longest contiguous run of bytes fetched from the front of this piece so far.
    // A retry or a hedge copy asks only for what is still missing and splices the two
    // halves, instead of downloading the whole piece again. Every kept byte came out
    // of a response whose 206 Content-Range was verified against this piece.
    _Prefix? prefix;
    void keepProgress(_Prefix? base, _Recorder recorder) {
      final bytes = (base?.bytes ?? 0) + recorder.bytes;
      if (bytes > (prefix?.bytes ?? 0) && bytes < piece.length) {
        prefix = _Prefix(
          bytes,
          base != null
              ? [...base.chunks, ...recorder.chunks]
              : recorder.chunks.toList(),
        );
      }
    }

    _Prefix? liveProgress(_Context? context) {
      if (context == null) return null;
      final chunks = context.recorder.chunks.toList();
      var bytes = context.base?.bytes ?? 0;
      for (final chunk in chunks) {
        bytes += chunk.length;
      }
      return _Prefix(
        bytes,
        context.base != null ? [...context.base!.chunks, ...chunks] : chunks,
      );
    }

    // Failing a piece ends acceleration for the whole video, and the list can be as short as
    // one working address. One slow reply must not decide that, so the list is walked again
    // after a pause; node health and bans have changed by then, so it is rebuilt each time.
    for (var round = 0; round < _pieceRounds; round += 1) {
      if (round != 0) {
        if (_now() - startedAt > _pieceRetryWindowMs) break;
        await _pause(roundPause(round), signal);
      }
      final candidates = _pieceCandidates(
        piece,
        resolver,
        preferredUrls,
        round,
      );
      final limit = min(8, candidates.length);
      final batchWidth = probe ? limit : 2;
      final tried = <Uri>{};
      while (tried.length < limit) {
        if (signal?.aborted ?? false) throw abortError(signal!.reason);
        // A node banned while this piece was waiting is skipped, unless only banned nodes are left.
        final untried = candidates
            .where((url) => !tried.contains(url))
            .toList();
        final open = untried.where(allowed).toList();
        final pair = (open.isNotEmpty ? open : untried)
            .take(batchWidth)
            .toList();
        if (pair.isEmpty) break;
        tried.addAll(pair);
        final controllers = [for (final _ in pair) RipperAbortController()];
        void cancelAll() {
          for (final controller in controllers) {
            controller.abort(abortError(signal?.reason));
          }
        }

        if (signal?.aborted ?? false) {
          cancelAll();
        } else {
          signal?.addListener(cancelAll);
        }
        // A first copy that is refused at once (HTTP 403) should not leave the piece idle
        // for the rest of the hedge delay.
        final firstFailure = Completer<void>();
        var firstStartedAt = 0.0, deadlineDeficitSamples = 0;
        final firstStraggler = Completer<void>();
        void firstBecameStraggler() {
          if (!firstStraggler.isCompleted) firstStraggler.complete();
        }

        void observeFirst(Map<String, Object?> event) {
          final etaMs = event['etaMs'] as int?;
          if (!hasDeadline || event['phase'] != 'progress' || etaMs == null) {
            return;
          }
          final bps = event['bps']! as double;
          final deadlineAt = deadlineNow();
          final missesDeadline =
              deadlineAt.isFinite && etaMs >= max(0, deadlineAt - _now());
          final slowerThanPeers =
              _connectionBps > 0 && bps < _connectionBps * 0.5 && etaMs >= 500;
          final remainingToDeadline = deadlineAt - _now();
          deadlineDeficitSamples =
              deadlineAt.isFinite && etaMs - remainingToDeadline >= 250
              ? deadlineDeficitSamples + 1
              : 0;
          // A clearly slow node is rescued immediately. If the whole route is slow,
          // two consecutive deficit samples may spend the same per-range rescue budget
          // (createEarlyHedge).
          if (deadlineAt.isFinite &&
              ((missesDeadline && slowerThanPeers) ||
                  deadlineDeficitSamples >= 2)) {
            firstBecameStraggler();
          }
        }

        final contexts = List<_Context?>.filled(pair.length, null);
        final attempts = <Future<_Result>>[];
        for (var pairIndex = 0; pairIndex < pair.length; pairIndex++) {
          final url = pair[pairIndex];
          attempts.add(() async {
            if (pairIndex != 0) {
              final waited = Completer<void>();
              Timer? timer;
              var settled = false, earlyClaimed = false;
              late final void Function() canceled;
              void finish(void Function() operation) {
                if (settled) return;
                settled = true;
                timer?.cancel();
                controllers[pairIndex].signal.removeListener(canceled);
                operation();
              }

              final measured = _hedgeDelayMs(settings);
              final delay = probe
                  ? 0
                  : startup
                  ? min(hasDeadline ? 200 : 250, measured)
                  : measured;
              double copyBps() => resolver.speed(url);
              // A playback-deadline request decides once its first copy has a connection (see
              // hedgeDue); one without a deadline (compatibility mode, the desktop client)
              // keeps the fixed hedge delay (hedgeDelayMs), counted from the moment the piece
              // asked, queue time included.
              void check() {
                if (settled) return;
                if (contexts[0] != null &&
                    _hedgeDue(
                      contexts[0]!,
                      delay,
                      deadlineNow(),
                      copyBps(),
                      earlyHedge,
                    )) {
                  return finish(waited.complete);
                }
                timer = Timer(_ms(50), check);
              }

              if (hasDeadline && !probe) {
                timer = Timer(Duration.zero, check);
              } else {
                timer = Timer(_ms(delay), () => finish(waited.complete));
              }
              unawaited(
                firstStraggler.future.then((_) {
                  if (settled ||
                      probe ||
                      earlyClaimed ||
                      !(earlyHedge?.claimProgress() ?? false)) {
                    return;
                  }
                  earlyClaimed = true;
                  timer?.cancel();
                  final grace = max(0, 250 - (_now() - firstStartedAt));
                  timer = Timer(_ms(grace), () => finish(waited.complete));
                }),
              );
              unawaited(
                firstFailure.future.then((_) => finish(waited.complete)),
              );
              canceled = () {
                finish(
                  () => waited.completeError(
                    abortError(controllers[pairIndex].signal.reason),
                  ),
                );
              };
              if (controllers[pairIndex].signal.aborted) {
                canceled();
              } else {
                controllers[pairIndex].signal.addListener(canceled);
              }
              await waited.future;
            }
            // Resume from the longest prefix known when the request really starts: an earlier
            // failed attempt, or what the still-running first copy has received by then.
            _Prefix? base;
            final recorder = _Recorder();
            _Plan begin() {
              if (pairIndex == 0) firstStartedAt = _now();
              base = prefix != null && prefix!.bytes >= _resumeMinBytes
                  ? prefix
                  : null;
              if (pairIndex != 0) {
                final live = liveProgress(contexts[0]);
                if (live != null &&
                    live.bytes >= _resumeMinBytes &&
                    live.bytes > (base?.bytes ?? 0)) {
                  base = live;
                }
              }
              if (base != null && base!.bytes >= piece.length) base = null;
              final startedAt = _now();
              contexts[pairIndex] = _Context(
                base,
                recorder,
                startedAt,
                piece.length - (base?.bytes ?? 0),
              );
              return _Plan(
                recorder,
                base != null
                    ? RipperPiece(
                        piece.index,
                        piece.start + base!.bytes,
                        piece.end,
                      )
                    : piece,
              );
            }

            try {
              final result = await _attempt(
                piece,
                url,
                controllers[pairIndex].signal,
                kind,
                resolver,
                priority + (pairIndex != 0 ? 20 : 0),
                begin,
                deadline,
                pairIndex != 0 ? null : observeFirst,
                probe
                    ? queueCritical
                    : startup
                    ? queueStartup
                    : queueOrdinary,
              );
              return base != null
                  ? _Result(
                      concatChunks([
                        ...base!.chunks,
                        result.bytes,
                      ], piece.length),
                      result.total,
                      result.url,
                    )
                  : result;
            } catch (_) {
              keepProgress(base, recorder);
              if (pairIndex == 0 && !firstFailure.isCompleted) {
                firstFailure.complete();
              }
              rethrow;
            }
          }());
        }
        try {
          final winner = await promiseAny(attempts);
          for (final controller in controllers) {
            if (!controller.signal.aborted) {
              controller.abort(RipperError.abort('并发副本已取消'));
            }
          }
          if (settings.autoConcurrency) {
            _autoConcurrency.delivered(piece.length);
          }
          return winner;
        } catch (aggregate) {
          lastError = lastErrorOf(aggregate);
          if (signal?.aborted ?? false) throw abortError(signal!.reason);
        } finally {
          signal?.removeListener(cancelAll);
        }
      }
    }
    throw lastError ?? RipperError('没有可用 CDN');
  }

  Future<_Result> _delayedAttempt(
    RipperPiece piece,
    Uri url,
    int delayMs,
    RipperAbortSignal? signal,
    String kind,
    RipperResolver resolver,
    RipperAbortController controller, [
    num priority = 0,
  ]) async {
    if (delayMs > 0) {
      final waited = Completer<void>();
      late final Timer timer;
      void canceled() {
        timer.cancel();
        if (!waited.isCompleted) {
          waited.completeError(abortError(controller.signal.reason));
        }
      }

      timer = Timer(_ms(delayMs), () {
        if (!waited.isCompleted) waited.complete();
      });
      if (controller.signal.aborted) {
        canceled();
      } else {
        controller.signal.addListener(canceled);
      }
      await waited.future;
    }
    if (signal?.aborted ?? false) throw abortError(signal!.reason);
    return _attempt(piece, url, controller.signal, kind, resolver, priority);
  }

  Future<_Result> _startupAttempt(
    RipperPiece piece,
    List<Uri> candidates,
    RipperResolver resolver,
    RipperRangeOptions options,
  ) async {
    final controllers = [for (final _ in candidates) RipperAbortController()];
    void cancelAll() {
      for (final controller in controllers) {
        if (!controller.signal.aborted) {
          controller.abort(abortError(options.signal?.reason));
        }
      }
    }

    if (options.signal?.aborted ?? false) {
      cancelAll();
    } else {
      options.signal?.addListener(cancelAll);
    }
    try {
      _Result winner;
      try {
        winner = await promiseAny([
          for (var index = 0; index < candidates.length; index++)
            _delayedAttempt(
              piece,
              candidates[index],
              index == 0
                  ? 0
                  : index == 1
                  ? 120
                  : 300,
              options.signal,
              options.kind ?? 'meta',
              resolver,
              controllers[index],
              220,
            ),
        ]);
      } catch (aggregate) {
        if (options.signal?.aborted ?? false) {
          throw abortError(options.signal!.reason);
        }
        throw lastErrorOf(aggregate);
      }
      for (final controller in controllers) {
        if (!controller.signal.aborted) {
          controller.abort(RipperError.abort('并发副本已取消'));
        }
      }
      return winner;
    } finally {
      options.signal?.removeListener(cancelAll);
    }
  }

  // Which address each piece tries first. The fastest node gets the most pieces, and a node
  // measured at under a twelfth of the best is left out entirely: a piece it starts has to
  // be rescued anyway. Its measurement goes stale after a while, and the resolver's
  // exploration slot then gives it, like any untested node, another try.
  int _assignTurn = 0;
  // Trials are counted per resolver: the video and the audio track take turns on this
  // downloader, and one shared count could leave a track without a trial for good.
  final _trialStates = Expando<_TrialState>();

  /// Upstream `assignPrimaries`, exposed for the fixture tests.
  List<Uri> assignPrimaries(
    List<Uri> urls,
    RipperResolver resolver,
    int count,
  ) {
    if (urls.isEmpty || count <= 0) return [];
    if (urls.length == 1) return List.filled(count, urls.first);
    // Each range opens one node further on, so ranges in flight together do not all
    // send their first pieces to the same node.
    final turn = _assignTurn;
    _assignTurn = (_assignTurn + 1) % 4096;
    double measure(Uri url) {
      final speed = resolver.speed(url);
      return speed.isNaN ? 0 : max(0, speed);
    }

    var known = urls.map(measure).toList();
    final positive = known.where((value) => value > 0);
    if (positive.isEmpty) {
      return List.generate(
        count,
        (index) => urls[(index + turn) % urls.length],
      );
    }
    final top = known.reduce(max);
    final eligible = [
      for (var index = 0; index < urls.length; index++)
        if (known[index] == 0 || known[index] >= top / 12) urls[index],
    ];
    if (eligible.isNotEmpty && eligible.length < urls.length) {
      urls = eligible;
      known = urls.map(measure).toList();
    }
    // A node without a measurement is a trial. It gets a piece or two from the end of the
    // range, which are needed last and may take longest, enough to measure it and cheap
    // when it turns out to be slow. With very few pieces there is none to spare.
    final unknown = [
      for (var index = 0; index < urls.length; index++)
        if (known[index] == 0) urls[index],
    ];
    var trials = min(unknown.length * 2, count ~/ 4);
    final trialState = _trialStates[resolver] ??= _TrialState();
    // Small segments never have a piece to spare, and a node left out for being slow would
    // stay unmeasured for good. Every fourth such range gives up its last piece for a trial.
    if (trials == 0 && unknown.isNotEmpty && count >= 2) {
      trialState.waited += 1;
      if (trialState.waited >= 4) trials = 1;
    }
    if (trials != 0) trialState.waited = 0;
    if (unknown.isNotEmpty) {
      urls = [
        for (var index = 0; index < urls.length; index++)
          if (known[index] != 0) urls[index],
      ];
      known = urls.map(measure).toList();
      count -= trials;
    }
    final weights = [for (final value in known) max(value, top * 0.05)];
    final total = weights.fold<double>(0, (sum, value) => sum + value);
    // Handed out in turns (smooth weighted round-robin), not in one block per node. The
    // pieces with the lowest numbers get the free connections first, and the player has
    // several segments in flight: with blocks, every segment's first pieces went to the
    // same node and the others sat idle.
    final primaries = <Uri>[];
    final credit = List<double>.filled(weights.length, 0);
    final order = [
      for (var index = 0; index < urls.length; index++)
        (index + turn) % urls.length,
    ];
    for (var index = 0; index < count; index += 1) {
      var best = order[0];
      for (final urlIndex in order) {
        credit[urlIndex] += weights[urlIndex];
        if (credit[urlIndex] > credit[best]) best = urlIndex;
      }
      credit[best] -= total;
      primaries.add(urls[best]);
    }
    for (var index = 0; index < trials; index += 1) {
      primaries.add(unknown[(index + trialState.cursor) % unknown.length]);
    }
    trialState.cursor = (trialState.cursor + trials) % 4096;
    return primaries;
  }

  List<Uri> _preferredFor(Uri? primary, List<Uri> urls) => primary != null
      ? [primary, ...urls.where((url) => url != primary)]
      : urls;

  static List<Uri> _unique(List<Uri> urls) {
    final seen = <Uri>{};
    return [
      for (final url in urls)
        if (seen.add(url)) url,
    ];
  }

  Future<RipperRangeResult> _downloadStartupRange(
    RipperPiece range,
    RipperResolver resolver,
    RipperRangeOptions options,
  ) async {
    _semaphore.setLimit(config().concurrency);
    final piece = RipperPiece(0, range.start, range.end);
    final startedAt = _now();
    Object? lastError;
    // The addresses that just failed are backing off by the next round, so each round
    // moves on to the next three.
    for (var round = 0; round < _pieceRounds; round += 1) {
      if (round != 0) {
        if (_now() - startedAt > _pieceRetryWindowMs) break;
        await _pause(roundPause(round), options.signal);
      }
      var candidates = _unique(resolver.startupCandidates()).take(3).toList();
      if (candidates.isEmpty && round != 0) {
        candidates = resolver.ordered(round).take(3).toList();
      }
      if (candidates.isEmpty) break;
      try {
        final winner = await _startupAttempt(
          piece,
          candidates,
          resolver,
          options,
        );
        return RipperRangeResult(
          bytes: winner.bytes,
          byteLength: null,
          pieceCount: 1,
          streamed: null,
          total: winner.total,
          hosts: [winner.url.host],
        );
      } catch (error) {
        if (options.signal?.aborted ?? false) {
          throw abortError(options.signal!.reason);
        }
        lastError = error;
      }
    }
    throw lastError ?? RipperError('没有可用 CDN');
  }

  Future<RipperRangeResult> _downloadStartupMediaRange(
    RipperPiece range,
    RipperResolver resolver,
    RipperRangeOptions options,
    double Function() deadline,
    RipperDownloadSettings settings,
  ) async {
    final effectiveConcurrency = settings.concurrency;
    _semaphore.setLimit(effectiveConcurrency);
    final candidateUrls = _unique(resolver.rangeCandidates());
    final headLength = min(
      range.length,
      max(64 * 1024, settings.minChunkBytes),
    );
    final head = RipperPiece(0, range.start, range.start + headLength - 1);
    final headResult = await _downloadPiece(
      head,
      resolver,
      options.signal,
      options.kind ?? 'media',
      candidateUrls,
      'probe',
      220,
      deadline,
    );
    await options.onOrderedChunk!(headResult.bytes, head, headResult.total);
    if (head.end >= range.end) {
      options.onStartupScheduled?.call();
      return RipperRangeResult(
        bytes: null,
        byteLength: range.length,
        pieceCount: 1,
        streamed: true,
        total: headResult.total,
        hosts: [headResult.url.host],
      );
    }

    final rescueReserve = max(1, min(16, (effectiveConcurrency / 8).ceil()));
    final mediaBudget = max(1, effectiveConcurrency - rescueReserve);
    final audioBudget = max(
      1,
      min(mediaBudget, (effectiveConcurrency / 8).ceil()),
    );
    final pieceBudget = options.kind == 'audio'
        ? audioBudget
        : max(1, mediaBudget - audioBudget);
    final pieces = [
      for (final piece in splitRange(
        head.end + 1,
        range.end,
        pieceBudget,
        _adaptiveMinChunk(
          settings,
          range.end - head.end,
          pieceBudget,
          candidateUrls.length,
        ),
      ))
        piece.withIndex(piece.index + 1),
    ];
    final delivery = _OrderedDelivery(pieces, options.onOrderedChunk);
    // The probe measured at least its own winner, so the pieces spread over the nodes by
    // speed at once; the proven address is among each piece's fallbacks, which
    // pieceCandidates orders by measured speed. Only the probe's winner and nodes with a
    // speed measurement carry the first segment: a node whose probe never finished would
    // otherwise get a share of it and hold up the start. The others stay available for
    // rescue, and later ranges try them.
    final provenUrls = candidateUrls
        .where((url) => url == headResult.url || resolver.speed(url) > 0)
        .toList();
    final primaries = assignPrimaries(
      provenUrls.isNotEmpty ? provenUrls : [headResult.url],
      resolver,
      pieces.length,
    );
    final earlyHedge = _EarlyHedge(rescueReserve);
    final fallbacks = [
      headResult.url,
      ...candidateUrls.where((url) => url != headResult.url),
    ];
    final pendingPieces = <Future<_Result>>[
      for (var orderedIndex = 0; orderedIndex < pieces.length; orderedIndex++)
        () async {
          final piece = pieces[orderedIndex];
          final result = await _downloadPiece(
            piece,
            resolver,
            options.signal,
            options.kind ?? 'media',
            _preferredFor(
              orderedIndex < primaries.length ? primaries[orderedIndex] : null,
              fallbacks,
            ),
            true,
            120 - min(30, piece.index),
            deadline,
            earlyHedge,
          );
          await delivery.add(orderedIndex, result);
          return result;
        }(),
    ];
    options.onStartupScheduled?.call();
    final results = await Future.wait(pendingPieces, eagerError: true);
    await delivery.done();
    final totals = [
      for (final item in [headResult, ...results])
        if (item.total != null) item.total!,
    ];
    if (totals.isNotEmpty && totals.any((value) => value != totals[0])) {
      throw RipperError('不同 CDN 返回的文件总长度不一致');
    }
    return RipperRangeResult(
      bytes: null,
      byteLength: range.length,
      pieceCount: pieces.length + 1,
      streamed: true,
      total: totals.isNotEmpty ? totals[0] : null,
      hosts: {
        for (final item in [headResult, ...results]) item.url.host,
      }.toList(),
    );
  }

  /// Upstream `downloadRange`: [range]'s bytes, from several nodes at once.
  Future<RipperRangeResult> downloadRange(
    RipperPiece range,
    RipperResolver resolver, [
    RipperRangeOptions options = const RipperRangeOptions(),
  ]) async {
    final settings = config();
    if (options.kind == 'meta') {
      return _downloadStartupRange(range, resolver, options);
    }
    // One deadline for the whole range, resolved at its boundary: every piece, including work
    // scheduled after the startup probe, refers to the same playback instant.
    final deadline = _deadlineOf(options);
    final parallel = options.parallel;
    if (options.startup && parallel && options.onOrderedChunk != null) {
      return _downloadStartupMediaRange(
        range,
        resolver,
        options,
        deadline,
        settings,
      );
    }
    final preferredUrls = parallel
        ? resolver.rangeCandidates()
        : resolver.urls();
    final globalConcurrency = parallel ? settings.concurrency : 1;
    final maxConcurrency = options.maxConcurrency;
    final requestedConcurrency =
        maxConcurrency != null && maxConcurrency.isFinite
        ? max(1, maxConcurrency.truncate())
        : globalConcurrency;
    final effectiveConcurrency = parallel
        ? min(globalConcurrency, requestedConcurrency)
        : 1;
    // Fewer primary pieces than slots is not a hard-reserved connection: it gives a
    // stalled piece's hedge/retry room to start immediately while the other primaries run.
    _semaphore.setLimit(globalConcurrency);
    final priority = options.priority;
    final basePriority = priority != null && priority.isFinite ? priority : 50;
    final rescueReserve = parallel && effectiveConcurrency >= 8
        ? min(8, max(1, (effectiveConcurrency / 8).ceil()))
        : 0;
    final pieceConcurrency = options.startup
        ? max(1, min(22, effectiveConcurrency))
        : max(1, effectiveConcurrency - rescueReserve);
    final pieces = splitRange(
      range.start,
      range.end,
      pieceConcurrency,
      parallel
          ? _adaptiveMinChunk(
              settings,
              range.length,
              pieceConcurrency,
              preferredUrls.length,
            )
          : maxSafeInteger,
    );
    final primaries = parallel
        ? assignPrimaries(preferredUrls, resolver, pieces.length)
        : const <Uri>[];
    final earlyHedge = _EarlyHedge(rescueReserve);
    final progressive = options.onOrderedChunk != null;
    final delivery = _OrderedDelivery(pieces, options.onOrderedChunk);
    final results = await Future.wait([
      for (final piece in pieces)
        () async {
          final result = await _downloadPiece(
            piece,
            resolver,
            options.signal,
            options.kind ?? 'media',
            _preferredFor(
              piece.index < primaries.length ? primaries[piece.index] : null,
              preferredUrls,
            ),
            options.startup,
            basePriority - min(20, piece.index),
            deadline,
            earlyHedge,
          );
          if (progressive) await delivery.add(piece.index, result);
          return result;
        }(),
    ], eagerError: true);
    if (progressive) await delivery.done();
    final totals = [
      for (final item in results)
        if (item.total != null) item.total!,
    ];
    if (totals.isNotEmpty && totals.any((value) => value != totals[0])) {
      throw RipperError('不同 CDN 返回的文件总长度不一致');
    }
    return RipperRangeResult(
      bytes: progressive
          ? null
          : concatChunks([
              for (final item in results) item.bytes,
            ], range.length),
      byteLength: range.length,
      pieceCount: pieces.length,
      streamed: progressive,
      total: totals.isNotEmpty ? totals[0] : null,
      hosts: {for (final item in results) item.url.host}.toList(),
    );
  }
}
