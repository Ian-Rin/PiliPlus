// fetch() for the downloader, over dart:io's HttpClient.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/btr/fetch.dart';

/// A [RipperFetch] over [client]. Aborting a request's signal aborts the
/// connection, and the pending fetch or read rejects with the abort reason,
/// as a browser's fetch does. Any other failure is a TypeError, like fetch's
/// network errors.
RipperFetch httpClientFetch(
  HttpClient client, {
  required String userAgent,
  String referer = 'https://www.bilibili.com/',
}) => (url, request) {
  final signal = request.signal;
  if (signal.aborted) return Future.error(signal.reason!);
  final response = Completer<RipperResponse>();
  HttpClientRequest? open;
  void onAbort() {
    open?.abort(signal.reason);
    if (!response.isCompleted) response.completeError(signal.reason!);
  }

  signal.addListener(onAbort);
  () async {
    try {
      final opened = await client.getUrl(url);
      if (signal.aborted) {
        opened.abort(signal.reason);
        return;
      }
      open = opened;
      opened.headers
        ..set(HttpHeaders.rangeHeader, request.rangeHeader)
        // A compressed body would not be the bytes the Range asked for.
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..set(HttpHeaders.refererHeader, referer);
      final received = await opened.close();
      if (signal.aborted) return;
      final contentRange = received.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      response.complete(
        RipperResponse(
          status: received.statusCode,
          headers: {'content-range': ?contentRange},
          body: _HttpBodyReader(received, signal),
        ),
      );
    } catch (error) {
      if (!response.isCompleted) {
        response.completeError(
          signal.aborted
              ? signal.reason!
              : RipperError('$error', name: 'TypeError'),
        );
      }
    }
  }();
  return response.future;
};

/// One chunk at a time, like a ReadableStream reader: the response stream is
/// paused until the next read, so an unread body does not pile up in memory.
class _HttpBodyReader implements RipperBodyReader {
  _HttpBodyReader(HttpClientResponse response, this._signal) {
    _subscription = response.listen(
      _data,
      onError: _error,
      onDone: _done,
      cancelOnError: true,
    )..pause();
    // Aborting a dart:io request once its response has arrived does not error
    // the response stream; a browser's fetch errors the body. Do that here.
    _signal.addListener(_aborted);
  }

  void _aborted() => unawaited(cancel(_signal.reason));

  final RipperAbortSignal _signal;
  late final StreamSubscription<List<int>> _subscription;
  final _queue = Queue<Uint8List>();
  Completer<Uint8List?>? _waiting;
  Object? _failure;
  bool _ended = false;

  void _data(List<int> data) {
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null) {
      waiting.complete(chunk);
    } else {
      _queue.add(chunk);
    }
    if (!_subscription.isPaused) _subscription.pause();
  }

  void _error(Object error) {
    _signal.removeListener(_aborted);
    _failure ??= _signal.aborted
        ? _signal.reason!
        : RipperError('$error', name: 'TypeError');
    _waiting?.completeError(_failure!);
    _waiting = null;
  }

  void _done() {
    _signal.removeListener(_aborted);
    _ended = true;
    _waiting?.complete(null);
    _waiting = null;
  }

  @override
  Future<Uint8List?> read() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeFirst());
    if (_failure != null) return Future.error(_failure!);
    if (_ended) return Future.value(null);
    final waiting = _waiting = Completer<Uint8List?>();
    _subscription.resume();
    return waiting.future;
  }

  @override
  Future<void> cancel(Object? reason) {
    _signal.removeListener(_aborted);
    if (_ended) return Future.value();
    _failure ??= reason ?? RipperError.abort();
    _waiting?.completeError(_failure!);
    _waiting = null;
    return _subscription.cancel();
  }
}
