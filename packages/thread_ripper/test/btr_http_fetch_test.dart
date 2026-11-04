import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/btr/fetch.dart';
import 'package:thread_ripper/btr/http_fetch.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late RipperFetch fetch;
  final seen = <HttpHeaders>[];
  // /slow answers after 300 ms; /stall sends one chunk and then nothing.
  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        seen.add(request.headers);
        // Unbuffered, so that /stall's first chunk leaves at once.
        final response = request.response..bufferOutput = false;
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 10-19/100');
        if (request.uri.path == '/stall') {
          response.add(Uint8List(5));
          await response.flush();
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        response.add(List.generate(10, (i) => 10 + i));
        await response.close();
      });
    client = HttpClient();
    fetch = httpClientFetch(client, userAgent: 'test-agent');
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<List<int>> readAll(RipperBodyReader body) async {
    final bytes = <int>[];
    while (true) {
      final chunk = await body.read();
      if (chunk == null) return bytes;
      bytes.addAll(chunk);
    }
  }

  test('a range: status, Content-Range, body and request headers', () async {
    final controller = RipperAbortController();
    final response = await fetch(
      url('/ok'),
      RipperRequest(start: 10, end: 19, signal: controller.signal),
    );
    expect(response.status, 206);
    expect(response.header('Content-Range'), 'bytes 10-19/100');
    expect(await readAll(response.body), List.generate(10, (i) => 10 + i));
    expect(seen.single.value(HttpHeaders.rangeHeader), 'bytes=10-19');
    expect(seen.single.value(HttpHeaders.acceptEncodingHeader), 'identity');
    expect(seen.single.value(HttpHeaders.userAgentHeader), 'test-agent');
    expect(
      seen.single.value(HttpHeaders.refererHeader),
      'https://www.bilibili.com/',
    );
  });

  test('aborting before the response rejects fetch with the reason', () async {
    final controller = RipperAbortController();
    final pending = fetch(
      url('/slow'),
      RipperRequest(start: 10, end: 19, signal: controller.signal),
    );
    Timer(
      const Duration(milliseconds: 50),
      () => controller.abort(RipperError.timeout('CDN 首字节超时')),
    );
    await expectLater(
      pending,
      throwsA(
        isA<RipperError>().having((e) => e.name, 'name', 'TimeoutError'),
      ),
    );
  });

  test('aborting mid-body rejects the pending read with the reason', () async {
    final controller = RipperAbortController();
    final response = await fetch(
      url('/stall'),
      RipperRequest(start: 10, end: 19, signal: controller.signal),
    );
    expect(await response.body.read(), hasLength(5));
    final next = response.body.read();
    controller.abort(RipperError.timeout('CDN 子块停止传输'));
    await expectLater(
      next,
      throwsA(
        isA<RipperError>().having((e) => e.name, 'name', 'TimeoutError'),
      ),
    );
  });

  test('a node that cannot be reached is a TypeError', () async {
    final port = server.port;
    await server.close(force: true);
    final controller = RipperAbortController();
    await expectLater(
      fetch(
        Uri.parse('http://127.0.0.1:$port/gone'),
        RipperRequest(start: 0, end: 0, signal: controller.signal),
      ),
      throwsA(isA<RipperError>().having((e) => e.name, 'name', 'TypeError')),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  test('an already aborted signal never connects', () async {
    final controller = RipperAbortController()..abort();
    await expectLater(
      fetch(
        url('/ok'),
        RipperRequest(start: 10, end: 19, signal: controller.signal),
      ),
      throwsA(isA<RipperError>().having((e) => e.name, 'name', 'AbortError')),
    );
    expect(seen, isEmpty);
  });
}
