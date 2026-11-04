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

class BtrRangeProxy {
  BtrRangeProxy({
    int concurrency = 8,
    this.overseas = true,
    this.customHosts = const [],
    this.autoConcurrency,
    required this.userAgent,
    this.referer = 'https://www.bilibili.com/',
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
  bool _closed = false;
  HttpServer? _server;
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  bool get _custom =>
      customHosts.any((host) => RipperCdnResolver.normalizeHost(host) != null);

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Download session closed');
    }
    _server = server;
    // A new video is a new playback session.
    autoConcurrency?.newSession();
    // A transport that goes away can also fail a close(); every request
    // cleans up after itself, so none of that reaches the app's zone.
    server.listen((request) => _serve(request).ignore());
  }

  /// The loopback URL that serves the track whose addresses are [urls].
  String register(Iterable<String> urls, {bool isAudio = false}) {
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
    );
  }

  /// [register] with the candidate list given (the loopback tests use it).
  String registerCandidates(
    List<Uri> urls, {
    List<Uri>? originals,
    bool isAudio = false,
  }) {
    if (_closed || _server == null || urls.isEmpty) {
      throw StateError('No download session or media candidates');
    }
    final id = '/$_token/${_tracks.length}';
    _tracks[id] = _Track(
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
    return 'http://127.0.0.1:${_server!.port}$id';
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

  /// Upstream's download() of the compatibility mode, for one window: a
  /// start unless it carries on where the track's last window ended; every
  /// piece checked against the window and the file before mpv gets it.
  Future<void> _window(
    _Track track,
    RipperPiece window,
    RipperAbortSignal signal,
    Future<void> Function(Uint8List bytes) deliver,
  ) async {
    // Only a start gets the startup treatment (racing the head on every node,
    // copying each piece early): the first media of a track, a seek, a retry.
    final following = track.warmEnd != 0 && window.start == track.warmEnd;
    var received = 0;
    int? total;
    try {
      final result = await _downloader.downloadRange(
        window,
        track.resolver,
        RipperRangeOptions(
          signal: signal,
          kind: track.kind,
          startup: !following,
          onOrderedChunk: (bytes, piece, fileTotal) async {
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
            await deliver(bytes);
          },
        ),
      );
      if (received != window.length || result.total != total) {
        throw RipperError('媒体 Range 长度不符');
      }
      if (track.warmEnd != 0 || window.length > _probeBytes) {
        track.warmEnd = window.end + 1;
      }
    } catch (_) {
      track.warmEnd = 0;
      rethrow;
    }
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
      Uint8List? head;
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
        // Headers go out with the first bytes, so a request that fails before
        // any arrive is a 502, not a stream cut short.
        _handedOver[job] = null;
        Future<void> deliver(Uint8List bytes) async {
          if (!sentHeaders) writeHead(status, end - start + 1, contentRange);
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
        var first = true;
        while (cursor <= end) {
          final size = windowBytes(kind: track.kind, first: first);
          final window = RipperPiece(0, cursor, min(end, cursor + size - 1));
          await _window(track, window, job.signal, deliver);
          cursor = window.end + 1;
          first = false;
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
}
