import 'dart:typed_data';

/// Where in a fragmented MP4 (Bilibili's DASH tracks) the fragment that
/// holds [at] starts, from the segment index (`sidx`) in the file's first
/// bytes ([head]); null if the head has no complete one.
///
/// It is the byte a player's seek to [at] reads from: ffmpeg (mpv's
/// demuxer) asked for the last fragment starting at or before the target,
/// checked against a Bilibili file (a seek to 60 s read from the fragment
/// at 55.02 s, the next starting at 60.02 s).
int? sidxFragmentAt(Uint8List head, Duration at) {
  final data = ByteData.sublistView(head);
  var box = 0;
  while (box + 8 <= head.length) {
    var size = data.getUint32(box);
    final type = String.fromCharCodes(head, box + 4, box + 8);
    var body = box + 8;
    if (size == 1) {
      if (box + 16 > head.length) return null;
      size = data.getUint64(box + 8);
      body = box + 16;
    } else if (size == 0) {
      return null; // to the end of the file: no sidx after it
    }
    if (size < body - box) return null;
    if (type == 'sidx') return _fragmentAt(data, box, body, size, at);
    box += size;
  }
  return null;
}

int? _fragmentAt(ByteData data, int box, int body, int size, Duration at) {
  if (box + size > data.lengthInBytes) return null;
  var p = body;
  final version = data.getUint8(p);
  p += 4 + 4; // version, flags, reference_ID
  final timescale = data.getUint32(p);
  p += 4;
  if (timescale == 0) return null;
  int time;
  int firstOffset;
  if (version == 0) {
    time = data.getUint32(p);
    firstOffset = data.getUint32(p + 4);
    p += 8;
  } else {
    time = data.getUint64(p);
    firstOffset = data.getUint64(p + 8);
    p += 16;
  }
  p += 2; // reserved
  final count = data.getUint16(p);
  p += 2;
  if (count == 0 || p + count * 12 > box + size) return null;
  final target =
      at.inMicroseconds * timescale ~/ Duration.microsecondsPerSecond;
  var offset = box + size + firstOffset;
  int? found;
  for (var i = 0; i < count; i++, p += 12) {
    final reference = data.getUint32(p);
    // A reference to another sidx: not the plain index Bilibili's files have.
    if (reference & 0x80000000 != 0) return null;
    if (time > target) break;
    found = offset;
    offset += reference & 0x7fffffff;
    time += data.getUint32(p + 4);
  }
  // Before the first fragment: the first.
  return found ?? box + size + firstOffset;
}
