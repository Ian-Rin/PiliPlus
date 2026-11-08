// mpv's side of Bilibili-thread-ripper: a loopback HTTP server that serves
// each registered track from BTR's own downloader (btr/downloader.dart).
//
// The counterpart of upstream's compatibility mode (src/native-range-transport.js):
// the player keeps decoding, buffering and seeking, and only its media requests
// are downloaded here. Upstream receives one bounded request per DASH segment;
// mpv asks for open-ended ranges (bytes=N-) on one connection per track, so a
// request is served as a run of bounded windows, one downloadRange each.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:thread_ripper/auto_concurrency.dart';
import 'package:thread_ripper/btr/downloader.dart';
import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/btr/fetch.dart';
import 'package:thread_ripper/btr/http_fetch.dart';
import 'package:thread_ripper/btr/range_core.dart';
import 'package:thread_ripper/btr/resolver.dart';
import 'package:thread_ripper/cdn_resolver.dart';

/// What [BtrRangeProxy.revive] found.
enum ProxyRevival {
  /// The server was taking connections.
  alive,

  /// It was not, and listens again on its port.
  relistened,

  /// It was not, and the port could not be had again (or the session is
  /// closed).
  failed,
}

class BtrRangeProxy {
  BtrRangeProxy({
    int concurrency = 8,
    this.overseas = true,
    this.customHosts = const [],
    this.autoConcurrency,
    required this.userAgent,
    this.referer = 'https://www.bilibili.com/',
    this.prefetchHeads = true,
    RipperFetch? fetch,
  }) : _settings = RipperDownloadSettings(
         concurrency: concurrency,
         autoConcurrency: autoConcurrency != null,
       ) {
    _downloader = RipperDownloader(
      fetch:
          fetch ??
          httpClientFetch(_client, userAgent: userAgent, referer: referer),
      getSettings: () => _settings,
      autoConcurrency: autoConcurrency,
    );
  }

  final bool overseas;
  final List<String> customHosts;
  final RipperAutoConcurrency? autoConcurrency;
  final String userAgent;
  final String referer;

  /// Whether [register] starts fetching each track's head (its length and
  /// first 64 KiB) at once, before mpv asks for it.
  final bool prefetchHeads;
  final RipperDownloadSettings _settings;
  late final RipperDownloader _downloader;

  /// The connection limit in force (the automatic count when it is on).
  int get concurrency => _downloader.concurrency;

  final _client = HttpClient()
    ..autoUncompress = false
    // Upstream's first-byte timeout covers connecting as well.
    ..connectionTimeout = const Duration(milliseconds: 5500);

  // One ban list for every track of the video, like upstream's options.cdnBans.
  final _bans = RipperBanList();
  final _tracks = <String, _Track>{};
  final _jobs = <RipperAbortController>{};

  // Every GET being served, and since when it has been waiting for mpv to
  // take the bytes it was handed (null while it is not).
  final _handedOver = <RipperAbortController, DateTime?>{};

  /// Whether mpv has stopped reading: every request being served has been
  /// waiting at least [_idleAfter] for mpv to take its bytes, which mpv does
  /// once its cache is full (the counterpart of mpv's demuxer-cache-idle).
  /// Free to read on the UI thread: a synchronous mpv property read waits for
  /// mpv's core and freezes the whole app while that is busy.
  bool get playerIdle {
    if (_handedOver.isEmpty) return false;
    final now = DateTime.now();
    return _handedOver.values.every(
      (since) => since != null && now.difference(since) >= _idleAfter,
    );
  }

  static const _idleAfter = Duration(milliseconds: 250);

  // Below the 30 to 50 of the window mpv is waiting for: the next window
  // only takes the connections the current one leaves free.
  static const _aheadPriority = 20;
  bool _closed = false;

  /// Startup diagnostics: short notes on a track's requests and first bytes,
  /// while set. No addresses.
  void Function(String note)? onTrace;
  HttpServer? _server;
  int? _port;
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  bool get _custom =>
      customHosts.any((host) => RipperCdnResolver.normalizeHost(host) != null);

  /// [newSession] false for a proxy made ahead of its video (the next in a
  /// list, while the one before still plays): [beginSession] once it is
  /// played.
  Future<void> start({bool newSession = true}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Download session closed');
    }
    // A new video is a new playback session.
    if (newSession) beginSession();
    _listen(server);
  }

  void beginSession() => autoConcurrency?.newSession();

  void _listen(HttpServer server) {
    _server = server;
    _port = server.port;
    // A transport that goes away can also fail a close(); every request
    // cleans up after itself, so none of that reaches the app's zone. A
    // listening socket taken back by the system ends the stream with an
    // error: [revive] listens again.
    server.listen(
      (request) => _serve(request).ignore(),
      onError: (Object _) {},
    );
  }

  /// iOS may take back a suspended app's listening sockets (Apple TN2277).
  /// Back in the foreground, mpv's connections to this server are refused,
  /// and every retry of the same address fails, after mpv has played what it
  /// had buffered. This checks that the server still takes connections and,
  /// if it does not, listens again on the same port: the addresses mpv holds
  /// go on working, with every track's state (its file length, nodes, bans).
  /// [ProxyRevival.failed] when the port could not be had again; the caller
  /// then reloads, and [reviveError] says why.
  ///
  /// The old socket is closed first, and closed through: Dart closes a
  /// socket asynchronously, and a bind made before that is done found the
  /// port still in use, now and then (a log showed one return relisten and a
  /// later one fail). The bind is tried a few times over a second besides.
  Future<ProxyRevival> revive() async {
    final port = _port;
    if (_closed || port == null) return ProxyRevival.failed;
    if (await _answers(port)) return ProxyRevival.alive;
    final old = _server;
    _server = null;
    if (old != null) {
      try {
        await old.close(force: true).timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    Object? error;
    for (var attempt = 0; attempt < _bindAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_bindRetryDelay);
      if (_closed) return ProxyRevival.failed;
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        if (_closed) {
          await server.close(force: true);
          return ProxyRevival.failed;
        }
        _listen(server);
        reviveError = null;
        return ProxyRevival.relistened;
      } catch (e) {
        error = e;
      }
    }
    reviveError = '$error';
    return ProxyRevival.failed;
  }

  /// Why the last [revive] could not listen again, for the logs.
  String? reviveError;

  static const _bindAttempts = 5;
  static const _bindRetryDelay = Duration(milliseconds: 250);

  /// Whether this server answers on [port]: an answer to a path only it
  /// knows (its token's), not just a connection, which anything listening
  /// on the port would take.
  Future<bool> _answers(int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    try {
      final request = await client.get('127.0.0.1', port, _alivePath);
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      response.listen(null).cancel().ignore();
      return response.statusCode == HttpStatus.noContent;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  String get _alivePath => '/$_token/alive';

  /// For tests: what iOS does to a suspended app's listening socket.
  Future<void> debugDropListener() async => _server?.close(force: true);

  /// The loopback URL that serves the track whose addresses are [urls].
  /// [warmBytes]: that much after the head downloads too, in the windows
  /// mpv's first request will take, before it asks (a video made ready
  /// ahead of time). At least the first window when above 0.
  String register(
    Iterable<String> urls, {
    bool isAudio = false,
    int warmBytes = 0,
  }) {
    final originals = urls
        .map(Uri.parse)
        .where(RipperCdnResolver.supports)
        .toList();
    return registerCandidates(
      RipperCdnResolver.candidates(
        urls,
        overseas: overseas,
        customHosts: customHosts,
      ),
      originals: originals,
      isAudio: isAudio,
      warmBytes: warmBytes,
    );
  }

  /// [register] with the candidate list given (the loopback tests use it).
  String registerCandidates(
    List<Uri> urls, {
    List<Uri>? originals,
    bool isAudio = false,
    int warmBytes = 0,
  }) {
    if (_closed || _server == null || urls.isEmpty) {
      throw StateError('No download session or media candidates');
    }
    final id = '/$_token/${_tracks.length}';
    final track = _tracks[id] = _Track(
      RipperCdnResolverAdapter(
        RipperCdnResolver(
          urls,
          bans: _bans,
          overseas: overseas,
          custom: _custom,
          originals: originals,
        ),
      ),
      isAudio ? 'audio' : 'video',
    );
    if (prefetchHeads || warmBytes > 0) {
      _prefetchHead(track, warmBytes: warmBytes);
    }
    return 'http://127.0.0.1:$_port$id';
  }

  /// mpv opens an EDL's tracks one after the other: the audio only once the
  /// video is open, its probe a few round trips after the video's. A browser's
  /// player asks for both init segments at once; fetching every head here as
  /// soon as the track is known does the same. A failure is forgotten: the
  /// request probes again, and answers 502 if that fails too.
  void _prefetchHead(_Track track, {int warmBytes = 0}) {
    final job = RipperAbortController();
    _jobs.add(job);
    track.headLoad = _probe(track, job.signal, fromStart: true)
        .then<void>(
          (bytes) {
            track.head = bytes;
            onTrace?.call('${track.kind} 开头已取到');
            if (warmBytes > 0) _warmWindows(track, warmBytes);
          },
          onError: (Object _) => onTrace?.call('${track.kind} 提前取开头失败'),
        )
        .whenComplete(() => _jobs.remove(job));
  }

  /// The windows mpv's first request takes after the head (see [_serve]),
  /// [bytes] of them (one at least), downloaded now and kept until then.
  /// Logs showed a start's head and first window take two to five seconds
  /// between them on a distant CDN, and a start from the first window alone
  /// wait half a second a moment later, for the next.
  void _warmWindows(_Track track, int bytes) {
    final total = track.total;
    final head = track.head;
    if (_closed || total == null || head == null || head.length >= total) {
      return;
    }
    final job = RipperAbortController();
    _jobs.add(job);
    final last = min(total - 1, head.length + bytes - 1);
    var from = head.length;
    var first = true;
    final windows = <_Window>[];
    do {
      final size = windowBytes(kind: track.kind, first: first);
      windows.add(
        _window(
          track,
          RipperPiece(0, from, min(total - 1, from + size - 1)),
          job.signal,
          startup: first,
          priority: first ? null : _aheadPriority,
        ),
      );
      from += size;
      first = false;
    } while (from <= last);
    track.warm
      ..clear()
      ..addAll(windows);
    Future.wait(windows.map((window) => window._done))
        .then(
          (_) => onTrace?.call(
            '${track.kind} 提前下好 ${windows.length} 个窗口 '
            '${windows.fold<int>(0, (sum, w) => sum + w.piece.length) ~/ 1024} KiB',
          ),
          onError: (Object _) {},
        )
        .whenComplete(() => _jobs.remove(job));
  }

  /// The next window downloaded ahead, if it is [piece]. Any other start
  /// (mpv asked elsewhere) leaves none: they are for one run from the head.
  _Window? _takeWarm(_Track track, RipperPiece piece) {
    if (track.warm.isEmpty) return null;
    final window = track.warm.first;
    if (!window.failed &&
        window.piece.start == piece.start &&
        window.piece.end == piece.end) {
      track.warm.removeAt(0);
      return window;
    }
    track.warm.clear();
    return null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final job in _jobs.toList()) {
      job.abort(RipperError.abort('加速任务已停止'));
    }
    _downloader.dispose();
    // Nothing is downloading for this player any more.
    autoConcurrency?.demand(0, concurrency, 0);
    _client.close(force: true);
    unawaited(_server?.close(force: true));
    _tracks.clear();
  }

  // ---------------------------------------------------------------------
  // Windows: how an open-ended mpv request becomes downloadRange calls.

  // The first bytes of a track, raced on three nodes like upstream's
  // init/index request. Every Bilibili media file is far longer.
  static const _probeBytes = 64 * 1024;

  /// How much of the file the next downloadRange covers. Upstream downloads
  /// one DASH segment per call, a few seconds of media, and the player asks
  /// for the next one when it is done; these windows play that part.
  /// - A window is one call: its pieces run in parallel, and the next window
  ///   starts when this one has been handed to mpv. mpv's own cache plays
  ///   on across the gap, as the browser's buffer does between segments.
  /// - A request's first window starts playback (upstream's startup range:
  ///   a raced head, then pieces), so it is kept short.
  /// - Upstream hands over whole pieces only. An audio window is about as
  ///   long as a Bilibili audio segment, so the audio does not wait for one
  ///   large piece that shares the link with the video (fork issue #5:
  ///   playback stopped two seconds in, once the head's audio ran out).
  static int windowBytes({required String kind, required bool first}) =>
      switch ((kind, first)) {
        ('audio', true) => 128 * 1024,
        ('audio', false) => 256 * 1024,
        (_, true) => 1024 * 1024,
        (_, false) => 2 * 1024 * 1024,
      };

  /// Upstream's download() of the compatibility mode, for one window, with
  /// every piece checked against the window and the file. [startup] is
  /// upstream's `!following`: a request's first window, unless it carries on
  /// where the track's last one ended (racing the head on every node, copying
  /// each piece early).
  ///
  /// The window downloads at once and keeps its bytes until it is attached
  /// (see _Window), so that the next one can download while mpv takes this
  /// one. Upstream waits for the player to ask for the next segment, which a
  /// browser does while it plays the last; between two windows that wait
  /// left every connection idle and the next window a round trip behind,
  /// too slow for fast playback on a distant CDN.
  _Window _window(
    _Track track,
    RipperPiece window,
    RipperAbortSignal signal, {
    required bool startup,
    num? priority,
  }) {
    final result = _Window(window);
    var received = 0;
    int? total;
    Future<void> run() async {
      final range = await _downloader.downloadRange(
        window,
        track.resolver,
        RipperRangeOptions(
          signal: signal,
          kind: track.kind,
          startup: startup,
          priority: priority,
          onStartupScheduled: result._markScheduled,
          onOrderedChunk: (bytes, piece, fileTotal) {
            if (signal.aborted) throw abortError(signal.reason);
            if (piece.start != window.start + received ||
                bytes.length != piece.length ||
                fileTotal == null ||
                fileTotal <= window.end ||
                fileTotal != track.total ||
                (total != null && total != fileTotal)) {
              throw RipperError('媒体 Range 校验失败');
            }
            total = fileTotal;
            received += bytes.length;
            return result._take(bytes);
          },
        ),
      );
      if (received != window.length || range.total != total) {
        throw RipperError('媒体 Range 长度不符');
      }
    }

    result._done = run();
    // Seen by attach(); a window given up before that must not reach the
    // app's zone as an unhandled error.
    result._done.then(
      (_) => result._markScheduled(),
      onError: (Object _) => result
        ..failed = true
        .._markScheduled(),
    );
    // A window that is not a start queues all of its pieces at once.
    if (!startup) result._markScheduled();
    return result;
  }

  /// The file's length, from a short "meta" range. From the file start it
  /// also returns those bytes, so the response's first bytes cost no extra
  /// round trip.
  Future<Uint8List?> _probe(
    _Track track,
    RipperAbortSignal signal, {
    required bool fromStart,
  }) async {
    final result = await _downloader.downloadRange(
      RipperPiece(0, 0, fromStart ? _probeBytes - 1 : 0),
      track.resolver,
      RipperRangeOptions(signal: signal, kind: 'meta'),
    );
    final total = result.total;
    if (total == null) throw RipperError('CDN 没有给出文件长度');
    track.total ??= total;
    if (total != track.total) throw RipperError('不同 CDN 返回的文件总长度不一致');
    return fromStart ? result.bytes : null;
  }

  // ---------------------------------------------------------------------
  // HTTP: mpv's requests.

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path == _alivePath) {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    final track = _tracks[request.uri.path];
    if (track == null || _closed) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final isGet = request.method == 'GET';
    if (!isGet && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    // dart:io never tells a handler that its client went away: writes to a
    // dead connection are dropped or flush() never returns. Own the socket
    // instead, so that mpv closing it (a seek, a demuxer reopen) ends this
    // request's downloads at once.
    final Socket socket;
    try {
      socket = await request.response.detachSocket(writeHeaders: false);
    } catch (_) {
      return;
    }
    final job = RipperAbortController();
    _jobs.add(job);
    void hangUp() => job.abort(RipperError.abort('播放器断开了连接'));
    job.signal.addListener(socket.destroy);
    socket.listen(
      null,
      onError: (Object _) => hangUp(),
      onDone: hangUp,
      cancelOnError: true,
    );
    unawaited(socket.done.then((_) {}, onError: (Object _) => hangUp()));
    if (isGet) {
      // mpv reads a track over one connection. Its next request (a seek, a
      // reopen) arrives before it closes the old one: stop the old one now.
      track.request?.abort(RipperError.abort('播放器换了读取位置'));
      track.request = job;
    }

    var sentHeaders = false;
    void writeHead(int status, int length, [String? contentRange]) {
      socket.add(
        ascii.encode(
          'HTTP/1.1 $status ${_reasons[status]}\r\n'
          'Content-Type: application/octet-stream\r\n'
          'Accept-Ranges: bytes\r\n'
          'Content-Length: $length\r\n'
          '${contentRange == null ? '' : 'Content-Range: $contentRange\r\n'}'
          'Connection: close\r\n'
          '\r\n',
        ),
      );
      sentHeaders = true;
    }

    try {
      final header = request.headers.value(HttpHeaders.rangeHeader);
      if (track.headLoad case final load?) await _race(load, job.signal);
      Uint8List? head = track.head;
      if (track.total == null) {
        head = await _probe(
          track,
          job.signal,
          fromStart: isGet && (header == null || header.startsWith('bytes=0-')),
        );
      }
      final total = track.total!;
      final (start, end) = parseRange(header, total);
      final status = header == null ? HttpStatus.ok : HttpStatus.partialContent;
      final contentRange = header == null ? null : 'bytes $start-$end/$total';
      if (!isGet) {
        writeHead(status, end - start + 1, contentRange);
      } else {
        // mpv asks again only for bytes its cache lacks: upstream's seek
        // outside the buffer, a new start.
        if (track.opened && start != track.warmEnd) {
          autoConcurrency?.newSession();
        }
        track.opened = true;
        onTrace?.call('${track.kind} 请求 ${header ?? '整个文件'}');
        var traced = false;
        // Headers go out with the first bytes, so a request that fails before
        // any arrive is a 502, not a stream cut short.
        _handedOver[job] = null;
        Future<void> deliver(Uint8List bytes) async {
          if (!sentHeaders) writeHead(status, end - start + 1, contentRange);
          if (!traced) {
            traced = true;
            onTrace?.call('${track.kind} 首批数据 ${bytes.length ~/ 1024} KiB');
          }
          socket.add(bytes);
          // flush() waits once the socket's buffers are full: mpv is not
          // reading (see playerIdle).
          _handedOver[job] = DateTime.now();
          try {
            await _race(socket.flush(), job.signal);
          } finally {
            if (_handedOver.containsKey(job)) _handedOver[job] = null;
          }
        }

        var cursor = start;
        if (head != null && start == 0) {
          final last = min(end, head.length - 1);
          await deliver(Uint8List.sublistView(head, 0, last + 1));
          cursor = last + 1;
        }
        // One window ahead: it downloads while mpv takes the current one,
        // queued behind it for connections (a lower priority).
        RipperPiece windowAt(int from, {required bool first}) {
          final size = windowBytes(kind: track.kind, first: first);
          return RipperPiece(0, from, min(end, from + size - 1));
        }

        _Window? ahead;
        if (cursor <= end) {
          final window = windowAt(cursor, first: true);
          if (_takeWarm(track, window) case final warm?) {
            onTrace?.call('${track.kind} 用提前下好的窗口');
            ahead = warm;
          } else {
            ahead = _window(
              track,
              window,
              job.signal,
              startup: !(track.warmEnd != 0 && window.start == track.warmEnd),
            );
          }
        }
        while (ahead != null) {
          final current = ahead;
          final next = current.piece.end + 1;
          final attached = current.attach(deliver)..ignore();
          // A start downloads its head first and queues its pieces after it:
          // the next window waits for those, as upstream's prefetch waits for
          // onStartupScheduled, or it would take the connections the first
          // picture needs while the head is on its way.
          await current.scheduled;
          if (next <= end && !job.signal.aborted) {
            final window = windowAt(next, first: false);
            ahead =
                _takeWarm(track, window) ??
                _window(
                  track,
                  window,
                  job.signal,
                  startup: false,
                  priority: _aheadPriority,
                );
          } else {
            ahead = null;
          }
          try {
            await attached;
          } catch (_) {
            track.warmEnd = 0;
            rethrow;
          }
          if (current.piece.start == start ||
              (head != null && start == 0 && current.piece.start == cursor)) {
            onTrace?.call(
              '${track.kind} 第一个窗口完成 ${current.piece.length ~/ 1024} KiB',
            );
          }
          if (track.warmEnd != 0 || current.piece.length > _probeBytes) {
            track.warmEnd = next;
          }
        }
      }
      await _race(socket.close(), job.signal);
    } on FormatException {
      try {
        writeHead(
          HttpStatus.requestedRangeNotSatisfiable,
          0,
          'bytes */${track.total}',
        );
        await _race(socket.close(), job.signal);
      } catch (_) {}
    } catch (_) {
      // Once the headers are out, the reset below shows mpv a stream cut
      // short instead of pretending it completed.
      if (!sentHeaders && !job.signal.aborted) {
        try {
          writeHead(HttpStatus.badGateway, 0);
          await _race(socket.close(), job.signal);
        } catch (_) {}
      }
    } finally {
      job.abort(RipperError.abort('请求已结束'));
      _jobs.remove(job);
      _handedOver.remove(job);
      if (identical(track.request, job)) track.request = null;
    }
  }

  /// [operation], or the abort reason as soon as [signal] aborts.
  static Future<T> _race<T>(Future<T> operation, RipperAbortSignal signal) {
    if (signal.aborted) return Future.error(abortError(signal.reason));
    final result = Completer<T>();
    void onAbort() {
      if (!result.isCompleted) result.completeError(abortError(signal.reason));
    }

    signal.addListener(onAbort);
    operation.then(
      (value) {
        signal.removeListener(onAbort);
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        signal.removeListener(onAbort);
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  static const _reasons = {
    HttpStatus.ok: 'OK',
    HttpStatus.partialContent: 'Partial Content',
    HttpStatus.requestedRangeNotSatisfiable: 'Range Not Satisfiable',
    HttpStatus.badGateway: 'Bad Gateway',
  };

  /// mpv's Range header against a file of [total] bytes: none, `a-b`, `a-`
  /// or the suffix `-n`. A FormatException means 416.
  static (int, int) parseRange(String? value, int total) {
    if (value == null) return (0, total - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      throw const FormatException('Invalid Range');
    }
    final int start;
    final int end;
    if (match[1]!.isEmpty) {
      final suffix = int.parse(match[2]!);
      if (suffix <= 0) throw const FormatException('Invalid suffix');
      start = max(0, total - suffix);
      end = total - 1;
    } else {
      start = int.parse(match[1]!);
      end = match[2]!.isEmpty
          ? total - 1
          : min(int.parse(match[2]!), total - 1);
    }
    if (start >= total || end < start) {
      throw const FormatException('Unsatisfiable Range');
    }
    return (start, end);
  }
}

class _Track {
  _Track(this.resolver, this.kind);

  final RipperResolver resolver;

  /// "video" or "audio", as upstream's track.kind.
  final String kind;

  /// The file's length, once a CDN has said.
  int? total;

  /// Where the last window delivered ended (upstream's track.warmEnd); 0 when
  /// the next window is a start.
  int warmEnd = 0;

  /// The GET being served; a newer one replaces it.
  RipperAbortController? request;
  bool opened = false;

  /// The head fetched when the track was registered: the first bytes of the
  /// file, once [headLoad] has completed (null if that failed).
  Future<void>? headLoad;
  Uint8List? head;

  /// The first window after [head], downloaded before mpv asked for it (see
  /// [BtrRangeProxy._warmWindows]), in file order; taken by the request
  /// that reads on from the head.
  final warm = <_Window>[];
}

/// One window's bytes on their way to mpv: kept in order until [attach],
/// then handed over as they arrive.
class _Window {
  _Window(this.piece);

  final RipperPiece piece;
  late final Future<void> _done;

  /// Whether its download failed (known once it is over).
  bool failed = false;
  final _scheduled = Completer<void>();
  final _kept = <Uint8List>[];

  /// Completes once every piece of this window is queued for a connection
  /// (or the window is over).
  Future<void> get scheduled => _scheduled.future;

  void _markScheduled() {
    if (!_scheduled.isCompleted) _scheduled.complete();
  }

  Future<void> Function(Uint8List bytes)? _deliver;

  Future<void> _take(Uint8List bytes) {
    final deliver = _deliver;
    if (deliver == null) {
      _kept.add(bytes);
      return Future.value();
    }
    return deliver(bytes);
  }

  /// Hands this window to mpv: what has arrived, then the rest as it comes.
  /// Completes once all of it has been handed over.
  Future<void> attach(Future<void> Function(Uint8List bytes) deliver) async {
    // Bytes that arrive during a handover join the queue; the last check and
    // the switch to [deliver] happen without a gap between them.
    while (_kept.isNotEmpty) {
      await deliver(_kept.removeAt(0));
    }
    _deliver = deliver;
    await _done;
  }
}
