import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/utils/flight_mode.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:thread_ripper/flight_record.dart';

/// 机上模式's 测量记录: what the link and playback did on a flight, written
/// to a file of its own, to set the mode's figures by afterwards (they
/// were set from two passengers' reports; docs/thread-ripper.md).
///
/// One line an event (the kinds: FlightRecord, which also reads them back
/// into a page of numbers). What is written:
/// - A small request every 15 s while the app is in front ([sync]): the
///   link's round trip, and when and for how long it was gone.
/// - Every video opened, its first picture, a look every 10 s, every wait
///   on the download, what the proxy's requests did (PlPlayerController).
/// - The app's own requests, a line a minute ([api]).
/// - The network test's results (FlightProbe).
///
/// Nothing of it leaves the phone unless the viewer sends it (设置 →
/// 播放器设置 → 机上测量). No address of a video, no account: qualities,
/// times and counts.
///
/// It must never be in playback's way: nothing here throws, and the file
/// is written a few seconds after the fact, one write at a time.
abstract final class FlightLog {
  static bool get recording => FlightMode.on && Pref.flightMeasure;

  /// Past this, the older half is dropped at the next start. A long flight
  /// with a video playing all the way is half a megabyte.
  static const _mostBytes = 4 * 1024 * 1024;

  static File? _file;
  static final _pending = <String>[];
  static Timer? _flush;
  static Future<void> _writing = Future.value();
  static int? _dayWritten;

  static Future<File> file() async {
    if (_file case final file?) return file;
    final dir = (await getApplicationDocumentsDirectory()).path;
    final file = File(p.join(dir, '.pili_flight.log'));
    try {
      if (!file.existsSync()) {
        await file.create(recursive: true);
      } else if (file.lengthSync() > _mostBytes) {
        final lines = await file.readAsLines();
        await file.writeAsString(
          '${lines.sublist(lines.length ~/ 2).join('\n')}\n',
          flush: true,
        );
      }
    } catch (_) {}
    return _file = file;
  }

  /// A line of [kind] (`hb 712`, `ev giveup`, `open`) with [fields].
  static void add(String kind, [Map<String, Object?> fields = const {}]) {
    if (!recording) return;
    try {
      final now = DateTime.now();
      final day = now.year * 10000 + now.month * 100 + now.day;
      if (_dayWritten != day) {
        _dayWritten = day;
        _pending.add(
          FlightRecord.day(
            now,
            'v1 ${BuildConfig.versionName} ${Platform.operatingSystem}'
            ' UTC${now.timeZoneOffset.isNegative ? '-' : '+'}'
            '${now.timeZoneOffset.inMinutes.abs() ~/ 60}',
          ),
        );
      }
      _pending.add(FlightRecord.line(now, kind, fields));
      _flush ??= Timer(const Duration(seconds: 5), flush);
    } catch (_) {}
  }

  static void event(String name, [Map<String, Object?> fields = const {}]) =>
      add('ev $name', fields);

  /// What is waiting is written. Each write after the one before.
  static Future<void> flush() {
    _flush?.cancel();
    _flush = null;
    if (_pending.isEmpty) return _writing;
    final text = '${_pending.join('\n')}\n';
    _pending.clear();
    return _writing = _writing.then((_) async {
      try {
        await (await file()).writeAsString(text, mode: FileMode.append);
      } catch (_) {}
    });
  }

  static Future<List<String>> lines() async {
    await flush();
    try {
      return await (await file()).readAsLines();
    } catch (_) {
      return const [];
    }
  }

  /// The record as a page of numbers (FlightRecord.summary).
  static Future<String> summary() async => FlightRecord.summary(await lines());

  static Future<void> clear() async {
    _pending.clear();
    _dayWritten = null;
    await flush();
    try {
      await (await file()).writeAsString('', flush: true);
    } catch (_) {}
  }

  // -------------------------------------------------------------------
  // The app's own requests (the play address, the video's page): a line a
  // minute, not one each.

  static final _apiMs = <int>[];
  static int _apiFailed = 0;
  static Timer? _apiLine;

  /// A request of the app's took [ms]; [answered]: the server did answer
  /// (with whatever status), which is what says the link was there.
  static void api(int ms, {required bool answered}) {
    if (!recording) return;
    if (answered) {
      if (_apiMs.length < 512) _apiMs.add(ms);
    } else {
      _apiFailed++;
    }
    _apiLine ??= Timer(const Duration(minutes: 1), () {
      _apiLine = null;
      final sorted = List.of(_apiMs)..sort();
      add('api', {
        'n': _apiMs.length + _apiFailed,
        'err': _apiFailed,
        'ms':
            '${FlightRecord.percentile(sorted, 0.5)}'
            '/${FlightRecord.percentile(sorted, 0.9)}',
      });
      _apiMs.clear();
      _apiFailed = 0;
    });
  }

  // -------------------------------------------------------------------
  // The link, whether or not a video plays: one small request every 15 s.

  static const _beatEvery = Duration(seconds: 15);
  static const _beatWithin = Duration(seconds: 10);

  /// Answers in a few hundred bytes (where the request came out, which is
  /// not read here), without an account.
  static final _beatUrl = Uri.https(
    'api.bilibili.com',
    '/x/web-interface/zone',
  );

  static Timer? _beat;
  static HttpClient? _beatClient;
  static bool _beating = false;

  /// Starts or stops the heartbeat by the settings as they are now: at the
  /// app's start, and when 机上模式 or the record is switched.
  static void sync() {
    if (recording) {
      _beat ??= Timer.periodic(_beatEvery, (_) => _heartbeat());
    } else {
      _beat?.cancel();
      _beat = null;
      _beatClient?.close(force: true);
      _beatClient = null;
      flush();
    }
  }

  static Future<void> _heartbeat() async {
    if (_beating || !recording) return;
    // In front only: behind, iOS holds the app's sockets back, and that
    // would read as the link gone.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _beating = true;
    final clock = Stopwatch()..start();
    try {
      // The connection is kept from one to the next (they are 15 s apart):
      // the time is then a round trip, not a handshake.
      final client = _beatClient ??= HttpClient()
        ..connectionTimeout = _beatWithin
        ..idleTimeout = const Duration(seconds: 60);
      await () async {
        final request = await client.getUrl(_beatUrl);
        request.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
        final response = await request.close();
        await response.drain<void>();
      }().timeout(_beatWithin);
      add('hb ${clock.elapsedMilliseconds}');
    } catch (_) {
      add('hb x');
      // What it was on is dead or hanging: the next one starts afresh.
      _beatClient?.close(force: true);
      _beatClient = null;
    } finally {
      _beating = false;
    }
  }
}
