import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/utils/flight_log.dart';
import 'package:PiliPlus/utils/flight_mode.dart';

/// 机上模式: where the link comes out, which is where Bilibili's nodes see
/// the viewer, wherever the aircraft is.
///
/// The nodes a video is fetched from are set once, for where the viewer
/// lives (线程撕裂者's region: the mainland's, the overseas ones, or the
/// mainland's with the overseas ones raced at a start). An airliner's link
/// comes out where its operator's ground station is: Xiamen Airlines' was
/// measured in Beijing, on China Telecom and Unicom. With the overseas
/// nodes set, every video would be fetched from Hong Kong or further, out
/// of the mainland and back, and the nodes Bilibili itself hands a Beijing
/// address (the mainland's) would be left out.
///
/// So the exit is asked for (one small request, the answer's country code
/// alone is kept), and while it is in the mainland the proxy uses the
/// mainland's nodes, whatever is set (PlPlayerController._newRipperProxy).
/// Anywhere else, or unknown, the setting stands.
abstract final class FlightExit {
  static final _url = Uri.https('api.bilibili.com', '/x/web-interface/zone');

  /// The mainland's country code in the answer (Hong Kong is 852, Macau
  /// 853, Taiwan 886).
  static const _mainlandCode = 86;

  /// An answer is good for this long: the exit moves when the aircraft
  /// passes from one satellite's ground station to another's.
  static const _goodFor = Duration(minutes: 30);
  static const _askEvery = Duration(minutes: 5);

  static int? _code;
  static DateTime? _knownAt;
  static DateTime _askedAt = DateTime(0);
  static bool _asking = false;

  /// Whether the link comes out in mainland China; null if 机上模式 is off
  /// or it is not known.
  static bool? get mainland {
    if (!FlightMode.on) return null;
    final at = _knownAt;
    final code = _code;
    if (at == null ||
        code == null ||
        DateTime.now().difference(at) > _goodFor) {
      return null;
    }
    return code == _mainlandCode;
  }

  /// The answer of the exit's request ([body]), from here or from the
  /// record's heartbeat, which asks the same address.
  static void note(String body) {
    try {
      final data = (jsonDecode(body) as Map)['data'];
      if (data is! Map) return;
      final code = data['country_code'];
      if (code is! int) return;
      if (code != _code) FlightLog.event('exit', {'cc': code});
      _code = code;
      _knownAt = DateTime.now();
    } catch (_) {}
  }

  /// Asks, unless it was asked in the last minutes. Not waited for: what
  /// it finds is for the next video.
  static void refresh() {
    if (!FlightMode.on || _asking) return;
    final now = DateTime.now();
    if (now.difference(_askedAt) < _askEvery) return;
    _askedAt = now;
    _asking = true;
    () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final body = await () async {
          final request = await client.getUrl(_url);
          request.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
          final response = await request.close();
          return response.transform(utf8.decoder).join();
        }().timeout(const Duration(seconds: 20));
        note(body);
      } catch (_) {
      } finally {
        client.close(force: true);
        _asking = false;
      }
    }();
  }

  /// 机上模式 was switched: nothing of the last flight is kept.
  static void reset() {
    _code = null;
    _knownAt = null;
    _askedAt = DateTime(0);
  }
}
