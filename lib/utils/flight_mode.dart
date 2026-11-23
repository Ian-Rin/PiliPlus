import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:thread_ripper/link_speed.dart';

/// 机上模式: for an airliner's satellite Wi-Fi (设置 → 播放器设置).
///
/// What such a link is like, as measured on Xiamen Airlines' 787s and
/// reported from others (docs/thread-ripper.md has the sources): 0.6 to
/// 0.8 s there and back, one TCP connection carrying 0.9 to 3.7 Mbit/s of
/// a link shaped to about 4 a passenger, a few percent of the packets lost,
/// and the link gone for seconds to minutes ("断联还是常态").
///
/// With it on:
/// - A video starts on its lowest quality and the 64 kbit/s sound: some
///   300 kbit/s together, which one connection carries. One quality above
///   that where the link has lately done three times its bitrate
///   ([carries]); back on the lowest, there and then, if that did not play.
/// - What the link and playback do is written down (FlightLog), to set
///   this mode's figures by after the flight.
/// - It plays through the thread-ripper proxy with a slow link's timings
///   (BtrRangeProxy.slowLink): few connections, nothing asked for twice,
///   long timeouts, and a link that is gone waited out, not given up.
/// - The player keeps ten minutes ahead (Pref.initBuffer), and takes a few
///   seconds more before it plays on after it ran dry.
/// - The sound comes first: a picture that has kept playback waiting
///   ([pictureWait]) is given up, the video opened again with its sound
///   alone (8 KiB/s), and tried again [soundOnlyFor] later, or when the
///   viewer asks for it (听视频 in the player's menu).
/// - A stream that broke off is opened again for minutes, and the API's
///   requests wait longer and are tried more often (Request, RetryInterceptor).
/// - What a video page asks for beside the video is left out: the related
///   videos, the seek preview's pictures; and the update check at the start.
abstract final class FlightMode {
  static bool get on => Pref.flightMode;

  /// The sound a video starts on.
  static int get audioQa => AudioQuality.k64.code;

  /// How long playback may have waited on the download, a quarter of the
  /// time it then played taken off again, before the picture is given up.
  /// A start takes 6 to 10 s on such a link when it carries the picture.
  static const pictureWait = 20;

  static const soundOnlyFor = Duration(minutes: 10);

  /// After the viewer asked for the picture, it is not given up again
  /// this long.
  static const _pictureKeptFor = Duration(minutes: 3);

  static DateTime? _soundOnlyUntil;
  static DateTime? _pictureKeptUntil;

  /// Whether the sound alone plays because the picture was given up
  /// ([giveUpPicture]), not because the viewer chose it: undone when that
  /// has run out.
  static bool byFallback = false;

  /// The picture was given up lately: a video opens with its sound alone.
  static bool get soundOnly {
    final until = _soundOnlyUntil;
    return on && until != null && DateTime.now().isBefore(until);
  }

  /// Whether a picture that keeps playback waiting may be given up now.
  static bool get mayGiveUpPicture {
    final kept = _pictureKeptUntil;
    return on && (kept == null || DateTime.now().isAfter(kept));
  }

  static void giveUpPicture() {
    _soundOnlyUntil = DateTime.now().add(soundOnlyFor);
    byFallback = true;
    // Nor a quality above the lowest when the picture is back.
    _link.failed();
  }

  // -------------------------------------------------------------------
  // One quality above the lowest, where the link carries it.

  /// What the link has done lately (see RipperLinkSpeed, which says how it
  /// is told): never kept across a restart, and of this mode alone.
  static final _link = RipperLinkSpeed();

  /// A speed the proxy measured on the video playing.
  static void noteSpeed(int kbps) => _link.note(kbps);

  /// The link's speed as known now, in kbit/s; null if it is not.
  static int? get linkKbps => _link.median();

  /// Whether a video may start on a stream of [bitsPerSecond] (picture and
  /// sound) that is not its lowest: the setting is on, the picture has not
  /// been given up, and the last ten minutes' speeds have a median of
  /// three times that.
  static bool carries(int bitsPerSecond) =>
      on &&
      Pref.flightRaiseQuality &&
      !soundOnly &&
      _link.carries(bitsPerSecond);

  /// Seconds a video raised a step may have kept playback waiting (the
  /// link there all the while) before it is opened again on its lowest
  /// quality: half of [pictureWait], which then decides on the picture.
  static const raisedWait = 10;

  /// The raised quality did not play: none is raised for ten minutes.
  static void raiseFailed() => _link.failed();

  /// The viewer turned 听视频 on or off: theirs from here on.
  static void viewerChose({required bool soundOnly}) {
    byFallback = false;
    _soundOnlyUntil = null;
    _pictureKeptUntil = soundOnly ? null : DateTime.now().add(_pictureKeptFor);
  }

  /// The mode was switched on or off: nothing of the last flight is kept.
  static void reset() {
    byFallback = false;
    _soundOnlyUntil = null;
    _pictureKeptUntil = null;
    _link.clear();
  }
}
