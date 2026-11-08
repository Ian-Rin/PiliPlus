// mpv's side of the BTR downloader: BtrRangeProxy against a loopback CDN.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:thread_ripper/auto_concurrency.dart';
import 'package:thread_ripper/btr/http_fetch.dart';
import 'package:thread_ripper/btr/range_proxy.dart';

void main() {
  late HttpServer cdn;
  late HttpClient client;
  late BtrRangeProxy proxy;
  late Uint8List source;
  late List<String> paths;
  late List<(String, int, int)> requests;
  late Set<int> interruptedEnds;
  late int active;
  late int peak;
  late List<Timer> timers;
  // When each request for /lag and /headlag reached the CDN: (start, ms).
  late List<(int, int)> lagArrivals;
  final clock = Stopwatch()..start();

  setUp(() async {
    source = Uint8List.fromList(List.generate(1100000, (i) => (i * 37) % 251));
    paths = [];
    requests = [];
    interruptedEnds = {};
    timers = [];
    lagArrivals = [];
    active = peak = 0;
    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        paths.add(request.uri.path);
        active++;
        peak = max(peak, active);
        final response = request.response;
        unawaited(
          response.done.then((_) => active--, onError: (Object _) => active--),
        );
        try {
          final range = BtrRangeProxy.parseRange(
            request.headers.value('range'),
            source.length,
          );
          final (start, end) = range;
          requests.add((request.uri.path, start, end));
          if (request.uri.path == '/lag' || request.uri.path == '/headlag') {
            lagArrivals.add((start, clock.elapsedMilliseconds));
          }
          if (request.uri.path == '/forbidden') {
            response.statusCode = 403;
            await response.close();
            return;
          }
          if (request.uri.path == '/ignored') {
            response.statusCode = 200;
            await response.close();
            return;
          }
          response.statusCode = 206;
          final reportedTotal = request.uri.path == '/changed' && start > 0
              ? source.length + 100
              : source.length;
          final reportedStart = request.uri.path == '/wrong'
              ? start + 1
              : start;
          response.headers.set(
            'Content-Range',
            'bytes $reportedStart-$end/$reportedTotal',
          );
          var body = source.sublist(start, end + 1);
          if (request.uri.path == '/resume-primary' &&
              start >= 65536 &&
              body.length > 65536) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            timers.add(
              Timer(const Duration(seconds: 3), () {
                try {
                  response.add(body.sublist(65536));
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path.startsWith('/pace')) {
            // The link is the limit: every connection receives at the same
            // steady 160 KiB/s, so pieces take longer than the hedge delay.
            var at = 0;
            void next() {
              try {
                if (at >= body.length) {
                  unawaited(response.close().catchError((Object _) {}));
                  return;
                }
                response.add(body.sublist(at, min(at + 16384, body.length)));
                at += 16384;
                timers.add(Timer(const Duration(milliseconds: 100), next));
              } catch (_) {}
            }

            next();
            return;
          }
          if (request.uri.path == '/trickle' && start >= 65536) {
            // Half of every piece now, the rest after a pause, like a piece
            // sharing a slow link with the others in flight.
            final half = body.length ~/ 2;
            response.add(body.sublist(0, half));
            await response.flush();
            timers.add(
              Timer(const Duration(seconds: 3), () {
                try {
                  response.add(body.sublist(half));
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path == '/resume' &&
              start >= 65536 &&
              body.length > 65536 &&
              interruptedEnds.add(end)) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            // Verified headers, then an interrupted body. The next request must
            // start at the last received byte, even on another CDN.
            await response.close();
            return;
          }
          if (request.uri.path == '/short') {
            body = body.sublist(0, body.length ~/ 2);
          }
          if (request.uri.path == '/large') {
            body = Uint8List.fromList([...body, 0]);
          }
          void send() {
            try {
              response.add(body);
              unawaited(response.close().catchError((Object _) {}));
            } catch (_) {}
          }

          if (request.uri.path == '/primary' && start >= 65536) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if ((request.uri.path == '/rescue' ||
                  request.uri.path == '/resume-backup') &&
              start < 65536) {
            timers.add(Timer(const Duration(milliseconds: 500), send));
          } else if (request.uri.path == '/jam' && end > start) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if (request.uri.path == '/seek' &&
              start > 0 &&
              start < 900000) {
            timers.add(Timer(const Duration(milliseconds: 200), send));
          } else if (request.uri.path == '/lag' &&
              start > 65536 &&
              start < 65536 + 128 * 1024) {
            // The first audio window's piece after its head is slow.
            timers.add(Timer(const Duration(milliseconds: 800), send));
          } else if (request.uri.path == '/headlag' && start == 65536) {
            // The first audio window's head is slow.
            timers.add(Timer(const Duration(milliseconds: 600), send));
          } else if (request.uri.path == '/slow') {
            timers.add(Timer(const Duration(seconds: 3), send));
          } else {
            // Different delays force out-of-order completion and real overlap.
            timers.add(Timer(Duration(milliseconds: start % 7 + 10), send));
          }
        } catch (_) {
          try {
            await response.close();
          } catch (_) {}
        }
      });
    client = HttpClient();
    // Most tests count the requests a fetch makes: no heads in advance.
    proxy = BtrRangeProxy(
      concurrency: 4,
      userAgent: 'test',
      prefetchHeads: false,
    );
    await proxy.start();
  });

  tearDown(() async {
    proxy.close();
    client.close(force: true);
    for (final timer in timers) {
      timer.cancel();
    }
    await cdn.close(force: true);
  });

  Uri endpoint(String path) => Uri.parse('http://127.0.0.1:${cdn.port}$path');
  String register(List<String> paths) =>
      proxy.registerCandidates(paths.map(endpoint).toList());
  Future<(HttpClientResponse, List<int>)> fetch(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final req = await client.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, bytes);
  }

  test(
    'parallel windows arrive in file order within the connection limit',
    () async {
      final results = await Future.wait([
        fetch(register(['/good'])),
        fetch(register(['/good']), range: 'bytes=3-800000'),
      ]);
      expect(results[0].$1.statusCode, 200);
      expect(results[0].$2, source);
      expect(results[1].$1.statusCode, 206);
      expect(results[1].$2, source.sublist(3, 800001));
      expect(peak, greaterThan(1));
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test('a request from the file start needs no separate probe', () async {
    final result = await fetch(register(['/good']));
    expect(result.$2, source);
    expect(requests.first, ('/good', 0, 65535));
    expect(requests.where((r) => r.$2 == 0 && r.$3 == 0), isEmpty);
  });

  test('HEAD, suffix, open-ended seek and 416 responses', () async {
    final url = register(['/good']);
    final head = await fetch(url, method: 'HEAD');
    expect(head.$1.contentLength, source.length);
    expect(head.$2, isEmpty);
    // A HEAD only needs the length: one byte, not the 64 KiB head.
    expect(requests.single, ('/good', 0, 0));
    expect(
      (await fetch(url, range: 'bytes=-19')).$2,
      source.sublist(source.length - 19),
    );
    expect(
      (await fetch(url, range: 'bytes=1099900-')).$2,
      source.sublist(1099900),
    );
    expect((await fetch(url, range: 'bytes=2000000-')).$1.statusCode, 416);
  });

  for (final bad in ['/forbidden', '/ignored', '/wrong', '/short', '/large']) {
    test(
      'rejects $bad and retries another CDN without corrupting bytes',
      () async {
        final result = await fetch(register([bad, '/good']));
        expect(result.$1.statusCode, 200);
        expect(result.$2, source);
        expect(paths, contains(bad));
        expect(paths, contains('/good'));
      },
    );
  }

  // Upstream accepts a piece whose Content-Range is right, and its
  // onOrderedChunk check finds the changed file length: the request fails
  // (mpv sees the stream cut short), it never gets wrong bytes.
  test(
    'a file length that changes midway cuts the stream, not the bytes',
    () async {
      final req = await client.getUrl(Uri.parse(register(['/changed'])));
      final res = await req.close();
      final received = <int>[];
      try {
        await res.forEach(received.addAll);
      } catch (_) {}
      expect(received.length, lessThan(source.length));
      expect(received, source.sublist(0, received.length));
    },
  );

  test('slow first response is raced before its first-byte timeout', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(
      register(['/slow', '/good']),
      range: 'bytes=0-100',
    );
    expect(result.$2, source.sublist(0, 101));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
    'all invalid upstream responses produce 502, never fake media bytes',
    () async {
      final result = await fetch(register(['/wrong']));
      expect(result.$1.statusCode, 502);
      expect(result.$2, isEmpty);
    },
  );

  test('session close cancels active and queued ranges promptly', () async {
    final url = register(['/slow']);
    final pending = fetch(url).then<Object>(
      (value) => value,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    proxy.close();
    await pending.timeout(const Duration(seconds: 1));
    final count = paths.length;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(paths.length, count);
  });

  test(
    'unknown paths cannot turn the listener into an arbitrary URL proxy',
    () async {
      final url = Uri.parse(register(['/good']));
      final result = await fetch(
        url.replace(path: '/https://example.com').toString(),
      );
      expect(result.$1.statusCode, 404);
      expect(paths, isEmpty);
    },
  );

  test(
    'a seek disconnect stops old work and new ranges remain usable',
    () async {
      source = Uint8List.fromList(
        List.generate(6 * 1024 * 1024, (i) => (i * 37) % 251),
      );
      final url = Uri.parse(register(['/seek']));
      final socket = await Socket.connect(url.host, url.port);
      socket.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
      await socket.flush();
      await socket.first;
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final oldCount = paths.length;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(paths.length, oldCount);
      // Work that outlived the disconnect would go on to later windows.
      expect(requests.every((r) => r.$2 < 2 * 1024 * 1024), isTrue);
      final next = await fetch(url.toString(), range: 'bytes=900000-900999');
      expect(next.$2, source.sublist(900000, 901000));
    },
  );

  test('a newer request for a track replaces the older one', () async {
    final url = Uri.parse(register(['/seek']));
    final older = await Socket.connect(url.host, url.port);
    older.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
    await older.flush();
    var received = 0;
    final started = Completer<void>();
    final ended = Completer<void>();
    older.listen(
      (data) {
        received += data.length;
        if (!started.isCompleted) started.complete();
      },
      onError: (Object _) {
        if (!ended.isCompleted) ended.complete();
      },
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
    );
    await started.future;
    // Like mpv's seek: the new range is requested while the old connection
    // is still open.
    final next = await fetch(url.toString(), range: 'bytes=900000-900999');
    expect(next.$2, source.sublist(900000, 901000));
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, lessThan(source.length));
    older.destroy();
  });

  test('a seek outside what was delivered starts a new session', () async {
    proxy.close();
    final auto = _CountingAuto();
    proxy = BtrRangeProxy(autoConcurrency: auto, userAgent: 'test');
    await proxy.start();
    expect((auto.sessions, auto.threads), (1, 16));
    final video = register(['/good']);
    final audio = proxy.registerCandidates([endpoint('/good')], isAudio: true);
    await fetch(video, range: 'bytes=0-1023');
    await fetch(audio, range: 'bytes=0-1023');
    await fetch(audio, method: 'HEAD');
    expect(auto.sessions, 1);
    final seek = await fetch(video, range: 'bytes=500000-500999');
    expect(seek.$2, source.sublist(500000, 501000));
    expect(auto.sessions, 2);
  });

  test(
    'a request that carries on where the last ended is no new start',
    () async {
      source = Uint8List.fromList(
        List.generate(3 * 1024 * 1024, (i) => (i * 37) % 251),
      );
      proxy.close();
      final auto = _CountingAuto();
      proxy = BtrRangeProxy(autoConcurrency: auto, userAgent: 'test');
      await proxy.start();
      final video = register(['/good']);
      final first = await fetch(video, range: 'bytes=0-1179647');
      expect(first.$2, source.sublist(0, 1179648));
      requests.clear();
      final next = await fetch(video, range: 'bytes=1179648-');
      expect(next.$2, source.sublist(1179648));
      expect(auto.sessions, 1);
      // No startup race: the window's first request is not a 64 KiB head.
      expect(requests.first.$3 - requests.first.$2 + 1, isNot(65536));
    },
  );

  // Upstream hands over whole pieces only: an audio window as long as a
  // Bilibili audio segment keeps the audio from waiting for one large piece.
  test('audio is downloaded in short windows', () async {
    final audio = proxy.registerCandidates([endpoint('/good')], isAudio: true);
    final result = await fetch(audio);
    expect(result.$2, source);
    final media = requests.where((r) => r.$2 >= 65536).toList();
    // The first window after the 64 KiB head is 128 KiB, the next ones 256 KiB.
    expect(media.every((r) => r.$3 - r.$2 + 1 <= 256 * 1024), isTrue);
    expect(media.map((r) => r.$2), contains(65536 + 128 * 1024));
    expect(media.map((r) => r.$2), contains(65536 + 128 * 1024 + 256 * 1024));
  });

  // While nothing is being written (a slow CDN), only the closed socket tells
  // the proxy that mpv has gone; its downloads must stop then, not at a
  // timeout.
  // (The loopback CDN cannot see a client go away either, so the test watches
  // the proxy's own requests being aborted.)
  test('a disconnect while waiting for the CDN stops the downloads', () async {
    proxy.close();
    final upstream = HttpClient();
    final real = httpClientFetch(upstream, userAgent: 'test');
    var started = 0, aborted = 0;
    proxy = BtrRangeProxy(
      userAgent: 'test',
      prefetchHeads: false,
      fetch: (url, request) {
        started++;
        request.signal.addListener(() => aborted++);
        return real(url, request);
      },
    );
    await proxy.start();
    final url = Uri.parse(register(['/slow']));
    final socket = await Socket.connect(url.host, url.port);
    socket.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((started, aborted), (1, 0));
    socket.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(aborted, 1);
    upstream.close(force: true);
  });

  test(
    'interrupted verified pieces resume without dropping or repeating bytes',
    () async {
      proxy.close();
      proxy = BtrRangeProxy(concurrency: 8, userAgent: 'test');
      await proxy.start();
      final result = await fetch(register(['/resume']));
      expect(result.$2, source);
      final pieces = requests.where((r) => r.$2 >= 65536).toList();
      expect(
        pieces.any((a) => pieces.any((b) => a.$3 == b.$3 && b.$2 > a.$2)),
        isTrue,
      );
    },
  );

  // mpv stops reading once its cache is full; the proxy then waits on the
  // socket, and says so without asking mpv (a synchronous property read can
  // freeze the app).
  test('playerIdle tells when mpv stops taking bytes', () async {
    source = Uint8List.fromList(
      List.generate(24 * 1024 * 1024, (i) => (i * 37) % 251),
    );
    expect(proxy.playerIdle, isFalse);
    final url = Uri.parse(register(['/good']));
    final socket = await Socket.connect(url.host, url.port);
    final subscription = socket.listen((_) {})..pause();
    socket.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
    await socket.flush();
    var idle = false;
    for (var i = 0; i < 100 && !idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      idle = proxy.playerIdle;
    }
    expect(idle, isTrue);
    // Reading again: the request goes on, and once it is over nothing waits.
    final done = Completer<void>();
    subscription
      ..onDone(done.complete)
      ..resume();
    await done.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(proxy.playerIdle, isFalse);
    await subscription.cancel();
    socket.destroy();
  });

  // mpv opens an EDL's audio only once the video is open; both heads are
  // fetched at once instead, before mpv asks for either.
  test('register fetches every head before mpv asks', () async {
    proxy.close();
    proxy = BtrRangeProxy(concurrency: 4, userAgent: 'test');
    await proxy.start();
    final video = register(['/good']);
    proxy.registerCandidates([endpoint('/good')], isAudio: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(requests, [('/good', 0, 65535), ('/good', 0, 65535)]);
    final result = await fetch(video);
    expect(result.$2, source);
    // The request starts from the head already there.
    expect(requests.where((r) => r.$2 == 0).length, 2);
    expect(
      (await fetch(video, method: 'HEAD')).$1.contentLength,
      source.length,
    );
  });

  test('a failed head in advance leaves the request its own probe', () async {
    proxy.close();
    proxy = BtrRangeProxy(concurrency: 4, userAgent: 'test');
    await proxy.start();
    final url = register(['/forbidden']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final before = requests.length;
    expect(before, greaterThan(0));
    final result = await fetch(url);
    expect(result.$1.statusCode, 502);
    expect(requests.length, greaterThan(before));
  });

  // The next video in a list is made ready while the one before ends: its
  // head and first window download before mpv asks for either.
  test('a warm track downloads its first windows ahead', () async {
    final notes = <String>[];
    proxy.onTrace = notes.add;
    // The head and two windows: the first (1 MiB) cut short by the file.
    final url = proxy.registerCandidates([
      endpoint('/good'),
    ], warmBytes: 2 * 1024 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(requests.where((r) => r.$2 == 0).length, 1);
    expect(requests.any((r) => r.$2 == 65536), isTrue);
    expect(notes.any((n) => n.startsWith('video 提前下好')), isTrue);
    final before = requests.length;
    final result = await fetch(url);
    expect(result.$2, source);
    expect(notes, contains('video 用提前下好的窗口'));
    // Head and first window cover the 1.1 MB file: nothing asked again.
    expect(requests.length, before);
    // A second request starts where it asks.
    final again = await fetch(url, range: 'bytes=70000-');
    expect(again.$2, source.sublist(70000));
  });

  test('the windows downloaded ahead are taken one after another', () async {
    source = Uint8List.fromList(List.generate(4000000, (i) => (i * 13) % 251));
    final notes = <String>[];
    proxy.onTrace = notes.add;
    // The first window (1 MiB) and the next (2 MiB).
    final url = proxy.registerCandidates([
      endpoint('/good'),
    ], warmBytes: 3 * 1024 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(notes, contains('video 提前下好 2 个窗口 3072 KiB'));
    final before = requests.length;
    final result = await fetch(url);
    expect(result.$2, source);
    // Only what lies past the windows downloaded ahead is asked for.
    final after = requests.skip(before).toList();
    expect(after, isNotEmpty);
    expect(after.every((r) => r.$2 >= 65536 + 3 * 1024 * 1024), isTrue);
  });

  test('a request elsewhere leaves the windows downloaded ahead', () async {
    final url = proxy.registerCandidates([
      endpoint('/good'),
    ], warmBytes: 64 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final result = await fetch(url, range: 'bytes=900000-');
    expect(result.$2, source.sublist(900000));
  });

  // Waiting for a window to reach mpv before asking for the next left every
  // connection idle for a round trip: too slow for fast playback.
  test('the next window downloads while mpv takes the current one', () async {
    final audio = proxy.registerCandidates([endpoint('/lag')], isAudio: true);
    final result = await fetch(audio);
    // The next window arrives first and waits for its turn.
    expect(result.$2, source);
    final firstMedia = lagArrivals
        .where((r) => r.$1 >= 65536)
        .map((r) => r.$2)
        .reduce(min);
    final ahead = lagArrivals
        .where((r) => r.$1 >= 65536 + 128 * 1024)
        .map((r) => r.$2)
        .reduce(min);
    expect(ahead - firstMedia, lessThan(600));
  });

  // Upstream's prefetch waits for onStartupScheduled: while a start's head
  // is on its way, the next window must not take the connections its
  // pieces are about to need.
  test('the next window waits for a start to queue its pieces', () async {
    final audio = proxy.registerCandidates([
      endpoint('/headlag'),
    ], isAudio: true);
    final result = await fetch(audio);
    expect(result.$2, source);
    int firstAt(bool Function(int start) where) =>
        lagArrivals.where((r) => where(r.$1)).map((r) => r.$2).reduce(min);
    final piece = firstAt((start) => start == 65536 + 64 * 1024);
    final ahead = firstAt((start) => start >= 65536 + 128 * 1024);
    expect(firstAt((start) => start == 65536), lessThan(piece));
    expect(ahead, greaterThanOrEqualTo(piece));
  });

  // The app logs a slow start's timeline (设置 → 日志).
  test('onTrace notes a track\'s startup without addresses', () async {
    proxy.close();
    proxy = BtrRangeProxy(concurrency: 4, userAgent: 'test');
    await proxy.start();
    final notes = <String>[];
    // The last note comes once the window is handed over, which can be just
    // after the client has read the last byte.
    final windowDone = Completer<void>();
    proxy.onTrace = (note) {
      notes.add(note);
      if (note.contains('第一个窗口完成')) windowDone.complete();
    };
    final url = register(['/good']);
    expect((await fetch(url)).$2, source);
    await windowDone.future.timeout(const Duration(seconds: 5));
    expect(notes, [
      'video 开头已取到',
      'video 请求 整个文件',
      'video 首批数据 64 KiB',
      // Cut short by the end of the 1.1 MB file.
      'video 第一个窗口完成 1010 KiB',
    ]);
    expect(notes.any((note) => note.contains('127.0.0.1')), isFalse);
  });

  // iOS may take back a suspended app's listening socket (TN2277); mpv
  // keeps the addresses it was given.
  test('revive listens again on the same port, tracks intact', () async {
    final url = register(['/good']);
    expect((await fetch(url, range: 'bytes=0-99')).$2, source.sublist(0, 100));
    expect(await proxy.revive(), ProxyRevival.alive);
    await proxy.debugDropListener();
    await expectLater(fetch(url, range: 'bytes=0-99'), throwsA(anything));
    expect(await proxy.revive(), ProxyRevival.relistened);
    expect(
      (await fetch(url, range: 'bytes=100-199')).$2,
      source.sublist(100, 200),
    );
    expect(
      (await fetch(url, range: 'bytes=1099900-')).$2,
      source.sublist(1099900),
    );
  });

  // The port can stay taken for a moment after the old socket goes (Dart
  // closes sockets asynchronously); one bind attempt failed there.
  test('revive waits for a port still in use for a moment', () async {
    final url = register(['/good']);
    expect((await fetch(url, range: 'bytes=0-99')).$2, source.sublist(0, 100));
    final port = Uri.parse(url).port;
    await proxy.debugDropListener();
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    // Past the alive check (up to a second), within the bind retries.
    Timer(const Duration(milliseconds: 1500), holder.close);
    expect(await proxy.revive(), ProxyRevival.relistened);
    expect(proxy.reviveError, isNull);
    expect(
      (await fetch(url, range: 'bytes=100-199')).$2,
      source.sublist(100, 200),
    );
  });

  test('a port that stays taken fails, and says why', () async {
    final url = register(['/good']);
    expect((await fetch(url, range: 'bytes=0-99')).$2, source.sublist(0, 100));
    final port = Uri.parse(url).port;
    await proxy.debugDropListener();
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(holder.close);
    expect(await proxy.revive(), ProxyRevival.failed);
    expect(proxy.reviveError, isNotNull);
  });

  test('a closed session does not come back', () async {
    proxy.close();
    expect(await proxy.revive(), ProxyRevival.failed);
  });

  test('a copy resumes the live first copy on a different node', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(register(['/resume-primary', '/resume-backup']));
    expect(result.$2, source);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    final originals = requests.where(
      (r) => r.$1 == '/resume-primary' && r.$2 >= 65536,
    );
    expect(
      originals.any(
        (a) => requests.any(
          (b) => b.$1 == '/resume-backup' && b.$3 == a.$3 && b.$2 > a.$2,
        ),
      ),
      isTrue,
    );
  });
}

class _CountingAuto extends RipperAutoConcurrency {
  int sessions = 0;

  @override
  void newSession() {
    sessions++;
    super.newSession();
  }
}
