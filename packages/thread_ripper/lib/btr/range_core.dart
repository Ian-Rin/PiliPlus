// Port of Bilibili-thread-ripper src/range-core.js (2026.11.3.1), MIT.
// Only the parts the downloader uses; the media-address checks live in
// cdn_resolver.dart.
import 'dart:typed_data';

/// One sub-range of a download. [index] is its place in the range.
class RipperPiece {
  const RipperPiece(this.index, this.start, this.end)
    : length = end - start + 1;

  final int index;
  final int start;
  final int end;
  final int length;

  RipperPiece withIndex(int index) => RipperPiece(index, start, end);

  @override
  bool operator ==(Object other) =>
      other is RipperPiece &&
      other.index == index &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(index, start, end);

  @override
  String toString() => 'RipperPiece($index, $start-$end)';
}

class RipperContentRange {
  const RipperContentRange(this.start, this.end, this.total);

  final int start;
  final int end;

  /// null for `bytes a-b/*`.
  final int? total;
  int get length => end - start + 1;
}

// Number.MAX_SAFE_INTEGER: larger numbers lose precision in JavaScript, and
// upstream rejects them.
const maxSafeInteger = 9007199254740991;
bool _safe(int? value) =>
    value != null && value >= 0 && value <= maxSafeInteger;

final _contentRange = RegExp(
  r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);

/// Upstream `parseContentRange`.
RipperContentRange? parseContentRange(String? value) {
  if (value == null) return null;
  final match = _contentRange.firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match[1]!);
  final end = int.tryParse(match[2]!);
  final total = match[3] == '*' ? null : int.tryParse(match[3]!);
  if (!_safe(start) || !_safe(end) || end! < start!) return null;
  if (match[3] != '*' && (!_safe(total) || total! <= end)) return null;
  return RipperContentRange(start, end, total);
}

/// Upstream `splitRange`: [concurrency] pieces at most, none shorter than
/// [minChunkBytes] (at least 32 KiB), the first ones one byte longer when the
/// length does not divide evenly.
List<RipperPiece> splitRange(
  int start,
  int end,
  num concurrency, [
  num minChunkBytes = 128 * 1024,
]) {
  final length = end - start + 1;
  final requested = concurrency.isFinite ? concurrency.truncate() : 0;
  final limit = (requested == 0 ? 1 : requested).clamp(1, 512);
  final chunk = minChunkBytes.isFinite ? minChunkBytes.truncate() : 0;
  final minimum = chunk == 0
      ? 128 * 1024
      : (chunk < 32 * 1024 ? 32 * 1024 : chunk);
  final count = (length / minimum).ceil().clamp(1, limit);
  final base = length ~/ count;
  final remainder = length % count;
  final pieces = <RipperPiece>[];
  var cursor = start;
  for (var index = 0; index < count; index++) {
    final size = base + (index < remainder ? 1 : 0);
    pieces.add(RipperPiece(index, cursor, cursor + size - 1));
    cursor += size;
  }
  return pieces;
}

/// Upstream `concatChunks`: the chunks back to back, exactly
/// [expectedLength] bytes long.
Uint8List concatChunks(Iterable<Uint8List> chunks, int expectedLength) {
  final output = Uint8List(expectedLength);
  var offset = 0;
  for (final bytes in chunks) {
    if (offset + bytes.length > expectedLength) {
      throw RangeError('子区间超出目标长度');
    }
    output.setRange(offset, offset + bytes.length, bytes);
    offset += bytes.length;
  }
  if (offset != expectedLength) {
    throw RangeError('子区间长度不符：$offset/$expectedLength');
  }
  return output;
}
