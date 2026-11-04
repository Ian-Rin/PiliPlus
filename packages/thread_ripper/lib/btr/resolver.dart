// The resolver contract of Bilibili-thread-ripper's downloader
// (src/cdn-resolver.js createResolver), MIT.
import 'package:thread_ripper/btr/errors.dart';
import 'package:thread_ripper/cdn_resolver.dart';

/// What the downloader asks of a track's node list: candidates in the
/// upstream orders, health and speed bookkeeping, and the ban list.
abstract interface class RipperResolver {
  /// Not banned (node, address or node/address pair).
  bool allows(Uri url);

  /// A request failed. An AbortError counts against nobody; [receivedBytes]
  /// tells a dead node from one that stalled midway.
  void failure(Uri url, Object? error, int receivedBytes);

  List<Uri> ordered([int pieceIndex = 0]);
  List<Uri> rangeCandidates();
  List<Uri> rescueCandidates();

  /// The speed of a transfer cut off before its end.
  void sample(Uri url, double bps);

  /// The measured speed, 0 when unknown or stale.
  double speed(Uri url);
  List<Uri> startupCandidates();

  /// The node answered; [bps] is 0 when the transfer was too short to measure.
  void success(Uri url, double bps);
  List<Uri> urls();
}

/// [RipperCdnResolver] (with its ban list) behind the upstream contract.
class RipperCdnResolverAdapter implements RipperResolver {
  RipperCdnResolverAdapter(this.cdn);

  final RipperCdnResolver cdn;

  @override
  bool allows(Uri url) => cdn.bans.allows(url);

  @override
  void failure(Uri url, Object? error, int receivedBytes) {
    if (errorName(error) == 'AbortError') return;
    cdn.failure(url, status: errorStatus(error) ?? 0, received: receivedBytes);
  }

  @override
  List<Uri> ordered([int pieceIndex = 0]) => cdn.ordered(pieceIndex);

  @override
  List<Uri> rangeCandidates() => cdn.rangeCandidates();

  @override
  List<Uri> rescueCandidates() => cdn.rescueCandidates();

  @override
  void sample(Uri url, double bps) => cdn.sample(url, bps);

  @override
  double speed(Uri url) => cdn.speed(url);

  @override
  List<Uri> startupCandidates() => cdn.startupCandidates();

  @override
  void success(Uri url, double bps) => cdn.recordSuccess(url, bps);

  @override
  List<Uri> urls() => cdn.unbannedUrls();
}
