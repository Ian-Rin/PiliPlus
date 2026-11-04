// The part of fetch() that Bilibili-thread-ripper's downloader uses, shaped
// like the browser's so the upstream code ports line for line.
import 'dart:typed_data';

import 'package:thread_ripper/btr/errors.dart';

/// One ranged GET: `Range: bytes=start-end`.
class RipperRequest {
  const RipperRequest({
    required this.start,
    required this.end,
    required this.signal,
    this.highPriority = false,
  });

  final int start;
  final int end;

  /// Aborting it rejects a pending fetch, and a pending read, with
  /// [RipperAbortSignal.reason].
  final RipperAbortSignal signal;

  /// fetch's `priority: "high"`, for requests the player waits on.
  final bool highPriority;

  String get rangeHeader => 'bytes=$start-$end';
}

/// A ReadableStreamDefaultReader over the response body.
abstract interface class RipperBodyReader {
  /// reader.read(): the next chunk, or null once the body has ended
  /// (`{ done: true }`). Rejects with the abort reason once the request is
  /// aborted.
  Future<Uint8List?> read();

  /// reader.cancel(reason): stop receiving.
  Future<void> cancel(Object? reason);
}

class RipperResponse {
  RipperResponse({
    required this.status,
    required Map<String, String> headers,
    required this.body,
  }) : _headers = {
         for (final entry in headers.entries)
           entry.key.toLowerCase(): entry.value,
       };

  final int status;
  final Map<String, String> _headers;
  final RipperBodyReader body;

  /// headers.get(name), case-insensitive.
  String? header(String name) => _headers[name.toLowerCase()];
}

/// fetch(url, { headers: { Range }, signal }): resolves once the response
/// headers arrive, rejects with the abort reason or a network error.
typedef RipperFetch = Future<RipperResponse> Function(
  Uri url,
  RipperRequest request,
);
