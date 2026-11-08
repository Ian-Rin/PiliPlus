// Runs the Dart port of Bilibili-thread-ripper's downloader through a scripted
// network on virtual time. The rules match tool/generate_btr_traces.cjs, which
// runs upstream's JavaScript through the same scripts; keep the two in step.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:thread_ripper/auto_concurrency.dart';
import 'package:thread_ripper/btr/downloader.dart';
import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/btr/fetch.dart';
import 'package:thread_ripper/btr/range_core.dart';
import 'package:thread_ripper/btr/resolver.dart';
import 'package:thread_ripper/cdn_resolver.dart';

const _dateBase = 1700000000000;

int byteAt(int o) => (o * 7 + (o >> 9)) & 255;

Duration _ms(num ms) => Duration(microseconds: (ms * 1000).round());

Map<String, Object?> _object(Object? value) =>
    Map<String, Object?>.from(value as Map? ?? const {});

/// network.default, then .hosts[host], then the matching .requests entry.
Map<String, Object?> mergeScenario(
  Map<String, Object?> defaults,
  Map<String, Object?> scenario,
) {
  final dn = _object(defaults['network']);
  final sn = _object(scenario['network']);
  return {
    ...defaults,
    ...scenario,
    'settings': {
      ..._object(defaults['settings']),
      ..._object(scenario['settings']),
    },
    'network': {
      'default': {..._object(dn['default']), ..._object(sn['default'])},
      'hosts': {..._object(dn['hosts']), ..._object(sn['hosts'])},
      'requests': [
        ...(dn['requests'] as List? ?? const []),
        ...(sn['requests'] as List? ?? const []),
      ],
    },
  };
}

class _Reader implements RipperBodyReader {
  _Reader(this._read);

  final Future<Uint8List?> Function() _read;

  @override
  Future<Uint8List?> read() => _read();

  // Aborting the request already errored the body (its abort listener runs first).
  @override
  Future<void> cancel(Object? reason) => Future.value();
}

/// Debugging aid: also log the resolver's success and sample calls (as
/// SUCCESS and SAMPLE events, which upstream traces do not have).
bool debugResolver = false;

class _LoggingResolver implements RipperResolver {
  _LoggingResolver(this.inner, this.log);
  final RipperResolver inner;
  final void Function(Map<String, Object?>) log;
  @override
  bool allows(Uri url) => inner.allows(url);
  @override
  void failure(Uri url, Object? error, int receivedBytes) =>
      inner.failure(url, error, receivedBytes);
  @override
  List<Uri> ordered([int pieceIndex = 0]) => inner.ordered(pieceIndex);
  @override
  List<Uri> rangeCandidates() => inner.rangeCandidates();
  @override
  List<Uri> startupRangeCandidates() => inner.startupRangeCandidates();
  @override
  List<Uri> rescueCandidates() => inner.rescueCandidates();
  @override
  void sample(Uri url, double bps) {
    log({'e': 'SAMPLE', 'host': url.host});
    inner.sample(url, bps);
  }

  @override
  double speed(Uri url) => inner.speed(url);
  @override
  List<Uri> startupCandidates() => inner.startupCandidates();
  @override
  void success(Uri url, double bps) {
    log({'e': 'SUCCESS', 'host': url.host});
    inner.success(url, bps);
  }

  @override
  List<Uri> urls() => inner.urls();
}

List<Map<String, Object?>> runScenario(Map<String, Object?> scenario) {
  final events = <Map<String, Object?>>[];
  fakeAsync((async) {
    num now() {
      final micros = async.elapsed.inMicroseconds;
      return micros % 1000 == 0 ? micros ~/ 1000 : micros / 1000;
    }

    void log(Map<String, Object?> event) => events.add({'t': now(), ...event});

    final network = _object(scenario['network']);
    final fileSize = scenario['fileSize']! as int;
    final nth = <String, int>{};
    Map<String, Object?> behaviour(String host) {
      final index = nth[host] ?? 0;
      nth[host] = index + 1;
      // Every matching entry applies, in order: one host (or "*") and its nth
      // request, or every request from fromNth on.
      final overrides = (network['requests']! as List).cast<Map>().where(
        (item) =>
            (item['host'] == host || item['host'] == '*') &&
            (item['nth'] == index ||
                (item['fromNth'] != null && index >= (item['fromNth'] as int))),
      );
      return {
        ..._object(network['default']),
        ..._object(_object(network['hosts'])[host]),
        for (final item in overrides) ..._object(item),
      };
    }

    Future<RipperResponse> fetch(Uri url, RipperRequest request) {
      final host = url.host;
      final s = request.start, x = request.end;
      final b = behaviour(host);
      final signal = request.signal;
      log({'e': 'fetch', 'host': host, 's': s, 'x': x});
      final response = Completer<RipperResponse>();
      var finished = false, responded = false, ended = false;
      final own = <Timer>[];
      final queue = Queue<Uint8List>();
      Object? failure;
      Completer<Uint8List?>? pending;
      void settle() {
        final waiter = pending;
        if (waiter == null) return;
        if (failure != null) {
          pending = null;
          waiter.completeError(failure!);
        } else if (queue.isNotEmpty) {
          pending = null;
          waiter.complete(queue.removeFirst());
        } else if (ended) {
          pending = null;
          waiter.complete(null);
        }
      }

      final reader = _Reader(() {
        if (failure != null) return Future.error(failure!);
        if (queue.isNotEmpty) return Future.value(queue.removeFirst());
        if (ended) return Future.value(null);
        return (pending = Completer<Uint8List?>()).future;
      });
      late final void Function() onAbort;
      onAbort = () {
        if (finished) return;
        finished = true;
        for (final timer in own) {
          timer.cancel();
        }
        log({
          'e': 'abort',
          'host': host,
          's': s,
          'x': x,
          'why': errorName(signal.reason),
        });
        failure = signal.reason;
        if (!responded) {
          response.completeError(signal.reason!);
        } else {
          settle();
        }
      };
      if (signal.aborted) {
        onAbort();
        return response.future;
      }
      signal.addListener(onAbort);
      own.add(
        Timer(_ms(b['headMs']! as num), () {
          responded = true;
          if (b['networkError'] == true) {
            finished = true;
            signal.removeListener(onAbort);
            response.completeError(
              RipperError('Failed to fetch', name: 'TypeError'),
            );
            return;
          }
          final status = b['status'] as int? ?? 206;
          if (status != 206) {
            finished = true;
            ended = true;
            response.complete(
              RipperResponse(status: status, headers: const {}, body: reader),
            );
            return;
          }
          final first = b['badRange'] == true ? s + 1 : s;
          final contentRange = 'bytes $first-$x/$fileSize';
          final length = x - s + 1;
          final endAfter = b['endAfter'] as int?;
          final stallAfter = b['stallAfter'] as int?;
          var limit = length;
          if (endAfter != null && endAfter < limit) limit = endAfter;
          if (stallAfter != null && stallAfter < limit) limit = stallAfter;
          final chunkBytes = b['chunkBytes']! as int;
          final chunkMs = b['chunkMs']! as num;
          var sent = 0;
          void send() {
            final size = chunkBytes < limit - sent ? chunkBytes : limit - sent;
            final chunk = Uint8List(size);
            for (var i = 0; i < size; i++) {
              chunk[i] = byteAt(s + sent + i);
            }
            sent += size;
            queue.add(chunk);
            if (sent >= limit && stallAfter == null) {
              ended = true;
              finished = true;
            }
            settle();
            if (sent < limit) own.add(Timer(_ms(chunkMs), send));
          }

          if (limit > 0) {
            own.add(Timer(_ms(chunkMs), send));
          } else if (stallAfter == null) {
            ended = true;
            finished = true;
          }
          response.complete(
            RipperResponse(
              status: status,
              headers: {'Content-Range': contentRange},
              body: reader,
            ),
          );
        }),
      );
      return response.future;
    }

    final rawSettings = _object(scenario['settings']);
    final settings = RipperDownloadSettings(
      concurrency: rawSettings['concurrency']! as int,
      autoConcurrency: rawSettings['autoConcurrency'] == true,
    );
    final auto = RipperAutoConcurrency(now: () => async.elapsed.inMilliseconds);
    final downloader = RipperDownloader(
      fetch: fetch,
      getSettings: () => settings,
      autoConcurrency: auto,
      now: () => async.elapsed.inMicroseconds / 1000,
    );
    final representation = _object(scenario['representation']);
    final originals = <String>[
      representation['baseUrl']! as String,
      ...(representation['backupUrl'] as List? ?? const []).cast<String>(),
    ];
    final mode = scenario['mode'];
    final customHosts = (scenario['customHosts'] as List? ?? const [])
        .cast<String>();
    final cdn = RipperCdnResolver(
      RipperCdnResolver.candidates(
        originals,
        overseas: mode == 'overseas',
        customHosts: customHosts,
      ),
      originals: originals
          .map(Uri.parse)
          .where(RipperCdnResolver.supports)
          .toList(),
      overseas: mode == 'overseas',
      custom: customHosts.isNotEmpty,
      now: () => DateTime.fromMicrosecondsSinceEpoch(
        _dateBase * 1000 + async.elapsed.inMicroseconds,
      ),
    );
    final RipperResolver resolver = debugResolver
        ? _LoggingResolver(RipperCdnResolverAdapter(cdn), log)
        : RipperCdnResolverAdapter(cdn);

    final calls = (scenario['calls']! as List).cast<Map>();
    for (var c = 0; c < calls.length; c++) {
      final call = Map<String, Object?>.from(calls[c]);
      final controller = RipperAbortController();
      Timer(_ms(call['at']! as num), () {
        final start = call['start']! as int, end = call['end']! as int;
        final range = RipperPiece(0, start, end);
        final kind = call['kind'] as String?;
        final progressive = call['progressive'] != false && kind != 'meta';
        var cursor = start;
        var ok = true;
        final options = RipperRangeOptions(
          signal: controller.signal,
          kind: kind,
          startup: call['startup'] == true,
          parallel: call['parallel'] != false,
          deadlineMs: (call['deadlineMs'] as num?)?.toDouble(),
          onOrderedChunk: progressive
              ? (bytes, piece, total) {
                  var good =
                      piece.start == cursor && bytes.length == piece.length;
                  for (var i = 0; good && i < bytes.length; i++) {
                    good = bytes[i] == byteAt(piece.start + i);
                  }
                  ok = ok && good;
                  cursor += bytes.length;
                  log({
                    'e': 'chunk',
                    'c': c,
                    's': piece.start,
                    'n': bytes.length,
                    'total': total,
                    'good': good,
                  });
                }
              : null,
        );
        downloader
            .downloadRange(range, resolver, options)
            .then(
              (result) {
                var good = ok;
                final bytes = result.bytes;
                if (bytes != null) {
                  good = bytes.length == range.length;
                  for (var i = 0; good && i < bytes.length; i++) {
                    good = bytes[i] == byteAt(start + i);
                  }
                } else if (progressive) {
                  good = ok && cursor == end + 1;
                }
                log({
                  'e': 'done',
                  'c': c,
                  'good': good,
                  'byteLength': result.byteLength,
                  'pieceCount': result.pieceCount,
                  'streamed': result.streamed,
                  'total': result.total,
                  'hosts': result.hosts,
                });
              },
              onError: (Object error) {
                log({
                  'e': 'fail',
                  'c': c,
                  'name': errorName(error),
                  'status': errorStatus(error),
                });
              },
            );
      });
      final abortAt = call['abortAt'] as num?;
      if (abortAt != null) Timer(_ms(abortAt), controller.abort);
    }

    // What the player tells the automatic thread count.
    auto.subscribe(() => log({'e': 'threads', 'n': auto.threads}));
    for (final signal
        in (scenario['signals'] as List? ?? const []).cast<Map>()) {
      Timer(_ms(signal['at']! as num), () {
        if (signal['stall'] == true) auto.stall();
        final buffer = signal['buffer'] as List?;
        if (buffer != null) {
          auto.buffer((buffer[0] as num).toDouble(), buffer[1] as bool);
        }
        if (signal['newSession'] == true) auto.newSession();
      });
    }
    async.elapse(_ms(scenario['runMs']! as num));
    downloader.dispose();
  });
  return events;
}

/// Events that happen at the same virtual millisecond may be logged in a
/// different order by the two event loops; within one millisecond they are
/// compared as a set.
List<String> canonicalEvents(List events) {
  String encode(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${encode(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(encode).join(',')}]';
    if (value is double && value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return jsonEncode(value);
  }

  final groups = SplayTreeMap<num, List<String>>();
  for (final event in events.cast<Map>()) {
    (groups[event['t'] as num] ??= []).add(encode(event));
  }
  return [
    for (final group in groups.values) ...(group..sort()),
  ];
}
