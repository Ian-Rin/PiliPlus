import 'dart:io' show Platform;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// A video's play address asked for as its card is pressed, before the
/// finger lifts: the press, the page's opening animation and the page's
/// setup take a few hundred milliseconds, which the address request (the
/// first wait of every start) now spends on its way. The video page takes
/// it ([take]) when it asks for the same video with the same parameters.
///
/// One at a time: a press elsewhere (a scroll that stopped on a card) puts
/// in its own, and a press not followed by a tap costs one request.
abstract final class PlayUrlPrefetch {
  static ({
    String bvid,
    int cid,
    bool tryLook,
    bool voiceBalance,
    DateTime at,
    Future<LoadingState<PlayUrlModel>> result,
  })?
  _last;

  /// Signed addresses last a couple of hours; this is for a tap right after.
  static const _freshFor = Duration(minutes: 2);

  /// As [PlPlayerController] has them for a video it plays.
  static bool get _tryLook =>
      !Accounts.get(AccountType.video).isLogin && Pref.p1080;
  static bool get _voiceBalance =>
      Platform.isAndroid && Pref.audioNormalization != '0';

  /// A plain video's (not an episode) address, as the video page's first
  /// request asks for it.
  static void start({required String? bvid, required int? cid}) {
    if (bvid == null || cid == null) return;
    final last = _last;
    if (last != null &&
        last.bvid == bvid &&
        last.cid == cid &&
        DateTime.now().difference(last.at) < _freshFor) {
      return;
    }
    // The CDN's connections open meanwhile too.
    PlPlayerController.warmCdn();
    final tryLook = _tryLook;
    final voiceBalance = _voiceBalance;
    _last = (
      bvid: bvid,
      cid: cid,
      tryLook: tryLook,
      voiceBalance: voiceBalance,
      at: DateTime.now(),
      result: VideoHttp.videoUrl(
        cid: cid,
        bvid: bvid,
        qn: VideoQuality.hdrVivid.code,
        tryLook: tryLook,
        videoType: VideoType.ugc,
        voiceBalance: voiceBalance,
      ),
    );
  }

  /// The address asked for at the press, when it is for this video with
  /// these parameters; taken once.
  static Future<LoadingState<PlayUrlModel>>? take({
    required String bvid,
    required int cid,
    required bool tryLook,
    required bool voiceBalance,
  }) {
    final last = _last;
    if (last == null || last.bvid != bvid || last.cid != cid) return null;
    _last = null;
    if (last.tryLook != tryLook ||
        last.voiceBalance != voiceBalance ||
        DateTime.now().difference(last.at) > _freshFor) {
      return null;
    }
    return last.result;
  }
}
