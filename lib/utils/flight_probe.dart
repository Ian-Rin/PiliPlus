import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/flight_exit.dart';
import 'package:PiliPlus/utils/flight_log.dart';
import 'package:thread_ripper/flight_record.dart';

/// 机上模式's network test (设置 → 播放器设置 → 机上测量 → 测一下网络): half a
/// minute of small measurements of the link, for what watching a video
/// does not show.
///
/// - How long a name takes to resolve, a TCP connection to open, a TLS one,
///   and a request to be answered on a connection that is open. On a
///   satellite link a round trip is 0.6 s and more; a TCP connection that
///   opens in a few milliseconds there is one a proxy on the aircraft
///   answered (a "PEP", which such links put in front of TCP), and that is
///   worth knowing: with one, TCP is carried well and a tunnel (a VPN) is
///   not.
/// - Where the link comes out (country, province, operator), which is
///   where Bilibili takes the viewer to be, and whose nodes it hands out.
/// - What one connection downloads, and what four do together, from the
///   node the last video came from: whether more connections bring more on
///   a link shaped for each passenger (机上模式 uses four).
///
/// It costs some 3.5 MB at most. Its results go to the record (FlightLog)
/// as one `probe` line, and to the page as text.
abstract final class FlightProbe {
  static bool _running = false;
  static bool get running => _running;

  static const _host = 'api.bilibili.com';
  static final _zone = Uri.https(_host, '/x/web-interface/zone');

  /// A video's addresses are signed for about two hours.
  static const _targetFreshFor = Duration(minutes: 100);

  /// [say] is told each result as it is known; all of them are returned.
  static Future<List<String>> run({void Function(String line)? say}) async {
    if (_running) return const [];
    _running = true;
    final out = <String>[];
    final fields = <String, Object?>{};
    void tell(String line) {
      out.add(line);
      try {
        say?.call(line);
      } catch (_) {}
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final dns = await _time(
        () =>
            InternetAddress.lookup(_host).timeout(const Duration(seconds: 10)),
      );
      fields['dns'] = dns ?? 'x';
      tell(dns == null ? '域名解析：失败' : '域名解析：$dns 毫秒');

      final tcp = <int>[];
      for (var i = 0; i < 3; i++) {
        final ms = await _time(() async {
          final socket = await Socket.connect(
            _host,
            443,
            timeout: const Duration(seconds: 10),
          );
          socket.destroy();
        });
        if (ms != null) tcp.add(ms);
      }
      fields['tcp'] = tcp.isEmpty ? 'x' : tcp.join('/');
      tell(tcp.isEmpty ? 'TCP 握手：失败' : 'TCP 握手：${tcp.join(' / ')} 毫秒');

      final tls = <int>[];
      for (var i = 0; i < 2; i++) {
        final ms = await _time(() async {
          final socket = await SecureSocket.connect(
            _host,
            443,
            timeout: const Duration(seconds: 15),
          );
          socket.destroy();
        });
        if (ms != null) tls.add(ms);
      }
      fields['tls'] = tls.isEmpty ? 'x' : tls.join('/');
      tell(
        tls.isEmpty ? 'TLS 握手：失败' : 'TLS 握手（含 TCP）：${tls.join(' / ')} 毫秒',
      );

      // One connection: the first request opens it, the rest are a round
      // trip each.
      final first = await _get(client, _zone);
      fields['first'] = first?.$1 ?? 'x';
      final trips = <int>[];
      var failed = 0;
      for (var i = 0; i < 8; i++) {
        final answer = await _get(client, _zone);
        if (answer == null) {
          failed++;
        } else {
          trips.add(answer.$1);
        }
      }
      trips.sort();
      fields['rtt'] = trips.isEmpty
          ? 'x'
          : '${trips.first}/${FlightRecord.percentile(trips, 0.5)}/${trips.last}';
      fields['fail'] = failed;
      tell(
        first == null ? '第一个请求（新连接）：失败' : '第一个请求（新连接）：${first.$1} 毫秒',
      );
      tell(
        trips.isEmpty
            ? '请求往返：8 次都失败'
            : '请求往返（已有连接，${trips.length} 次，失败 $failed）：'
                  '最小 ${trips.first} / 中位 ${FlightRecord.percentile(trips, 0.5)}'
                  ' / 最大 ${trips.last} 毫秒',
      );
      if (tcp.isNotEmpty && trips.isNotEmpty) {
        final connect = (List.of(tcp)..sort())[tcp.length ~/ 2];
        final trip = FlightRecord.percentile(trips, 0.5);
        final proxied = trip >= 300 && connect * 3 < trip;
        fields['pep'] = proxied;
        tell(
          proxied
              ? '→ TCP 握手比一次往返快得多：机上有 TCP 加速代理（PEP），不要开 VPN'
              : trip < 300
              ? '→ 往返不到 0.3 秒：这不像卫星链路'
              : '→ TCP 握手和一次往返差不多：没看到 TCP 加速代理',
        );
      }

      final zone = _zoneOf(first?.$2);
      if (zone != null) {
        fields['zone'] = zone;
        tell('出口位置：$zone');
      }
      // The same answer says which nodes 机上模式 uses (FlightExit).
      if (first != null) FlightExit.note(first.$2);
      switch (FlightExit.mainland) {
        case true:
          tell('→ 出口在大陆：机上模式用大陆节点，不管设置的地区是什么');
        case false:
          tell('→ 出口不在大陆：节点按设置的地区选');
        case null:
          break;
      }

      await _speed(tell, fields);
    } catch (_) {
      tell('测试中断');
    } finally {
      client.close(force: true);
      _running = false;
    }
    FlightLog.add('probe', fields);
    FlightLog.flush();
    return out;
  }

  /// How long [action] took in milliseconds; null if it failed.
  static Future<int?> _time(Future<void> Function() action) async {
    final clock = Stopwatch()..start();
    try {
      await action();
      return clock.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  static Future<(int, String)?> _get(HttpClient client, Uri url) async {
    final clock = Stopwatch()..start();
    try {
      return await () async {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        return (clock.elapsedMilliseconds, body);
      }().timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
  }

  /// Country, province, city and operator of where the request came out,
  /// from the answer's own words. Not the address.
  static String? _zoneOf(String? body) {
    if (body == null) return null;
    try {
      final data = (jsonDecode(body) as Map)['data'];
      if (data is! Map) return null;
      final parts = [
        for (final key in const ['country', 'province', 'city', 'isp'])
          if (data[key] case final String value when value.isNotEmpty) value,
      ];
      return parts.isEmpty ? null : parts.join('/');
    } catch (_) {
      return null;
    }
  }

  static const _oneBytes = 1536 * 1024;
  static const _eachBytes = 512 * 1024;

  static Future<void> _speed(
    void Function(String line) tell,
    Map<String, Object?> fields,
  ) async {
    final target = PlPlayerController.flightProbeTarget;
    if (target == null ||
        DateTime.now().difference(target.at) > _targetFreshFor) {
      tell('下载速度：没测（先放任意一个视频，再回来测）');
      return;
    }
    for (final address in target.urls.take(2)) {
      final Uri url;
      try {
        url = Uri.parse(address);
      } catch (_) {
        continue;
      }
      final one = await _download(url, const [(0, _oneBytes - 1)]);
      if (one == null) continue;
      fields['host'] = url.host;
      fields['one'] = '${one.kbps}kbps';
      fields['onefb'] = one.firstByteMs;
      tell(
        '下载速度，1 条连接：${one.kbps} kbit/s'
        '（${one.bytes ~/ 1024} KiB，首字节 ${one.firstByteMs} 毫秒）',
      );
      final four = await _download(url, [
        for (var i = 0; i < 4; i++)
          (
            _oneBytes + i * _eachBytes,
            _oneBytes + (i + 1) * _eachBytes - 1,
          ),
      ]);
      if (four == null) {
        tell('下载速度，4 条连接：失败');
        return;
      }
      fields['four'] = '${four.kbps}kbps';
      fields['fourfb'] = four.firstByteMs;
      tell(
        '下载速度，4 条连接：${four.kbps} kbit/s'
        '（${four.bytes ~/ 1024} KiB，首字节 ${four.firstByteMs} 毫秒）',
      );
      tell(
        four.kbps * 10 > one.kbps * 13
            ? '→ 4 条连接比 1 条快 ${(four.kbps / max(1, one.kbps)).toStringAsFixed(1)} 倍'
            : '→ 4 条连接没有比 1 条快多少：链路是按人限速的',
      );
      return;
    }
    tell('下载速度：失败（视频地址可能过期了，重新放一个视频再测）');
  }

  /// [ranges] of [url], each on a connection of its own, for twelve
  /// seconds at most: the speed from the first byte to the last, in
  /// kbit/s. Null if nothing came.
  static Future<({int kbps, int firstByteMs, int bytes})?> _download(
    Uri url,
    List<(int, int)> ranges,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final clock = Stopwatch()..start();
    int? firstAt;
    var lastAt = 0;
    var bytes = 0;
    try {
      await Future.wait([
        for (final (start, end) in ranges)
          () async {
            try {
              final request = await client.getUrl(url);
              request.headers
                ..set(HttpHeaders.userAgentHeader, BrowserUa.pc)
                ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com/')
                ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
              final response = await request.close();
              if (response.statusCode != HttpStatus.partialContent) {
                await response.drain<void>();
                return;
              }
              await for (final chunk in response) {
                firstAt ??= clock.elapsedMilliseconds;
                lastAt = clock.elapsedMilliseconds;
                bytes += chunk.length;
              }
            } catch (_) {}
          }(),
      ]).timeout(const Duration(seconds: 12), onTimeout: () => const []);
    } catch (_) {
    } finally {
      // Cuts off what is still coming.
      client.close(force: true);
    }
    final first = firstAt;
    if (first == null || bytes == 0) return null;
    return (
      kbps: bytes * 8 ~/ max(1, lastAt - first),
      firstByteMs: first,
      bytes: bytes,
    );
  }
}
