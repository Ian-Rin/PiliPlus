import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class UrlUtils {
  // 302重定向路由截取
  static Future<String?> parseRedirectUrl(String url) async {
    // b23.tv redirects the address as it is shared, without a slash at its
    // end (302, Location). With one, which this used to add, it now answers
    // 200 with "-404 啥都木有" and no Location: a log showed four taps on a
    // short link fail, three tries each. The address is asked as it is
    // given first, then with the slash the other way.
    //
    // A redirect that only adds or drops that slash is none: bilibili.com
    // answers /read/cv1 with a 301 to /read/cv1/, and an article is asked
    // here to see whether it has moved elsewhere.
    String bare(String address) => address.endsWith('/')
        ? address.substring(0, address.length - 1)
        : address;
    // Given with a slash, an address is asked without only where the slash
    // is known to break it: an article's (the one caller that gives one)
    // answers 200 at once, and is not asked twice.
    final other = !url.endsWith('/')
        ? '$url/'
        : (Uri.tryParse(url)?.host.endsWith('b23.tv') ?? false)
        ? bare(url)
        : null;
    for (final address in [url, ?other]) {
      try {
        final response = await Request.dio.head(
          address,
          options: Options(
            followRedirects: false,
            validateStatus: (status) => 200 <= status! && status < 400,
            extra: {'account': AnonymousAccount()},
          ),
        );
        var redirectUrl = response.headers['location']?.firstOrNull;
        if (kDebugMode) debugPrint('redirectUrl: $redirectUrl');
        if (redirectUrl == null) continue;
        if (!redirectUrl.startsWith('http')) {
          redirectUrl = Uri.parse(address).resolve(redirectUrl).toString();
        }
        if (bare(redirectUrl) == bare(address)) continue;
        return redirectUrl;
      } catch (_) {}
    }
    return null;
  }

  // 匹配url路由跳转
  static Future<void> matchUrlPush(
    String pathSegment,
    String redirectUrl,
  ) async {
    final matchRes = IdUtils.matchAvorBv(input: pathSegment);
    if (matchRes.isNotEmpty) {
      final aid = matchRes.av;
      final bvid = matchRes.bv;
      final res = await SearchHttp.ab2cWithDimension(aid: aid, bvid: bvid);
      final cid = res?.cid;
      if (cid != null) {
        PageUtils.toVideoPage(
          aid: aid,
          bvid: bvid,
          cid: cid,
          dimension: res!.dimension,
          // title: res.title,
        );
      }
    } else {
      if (redirectUrl.isNotEmpty) {
        PageUtils.handleWebview(redirectUrl);
      } else {
        SmartDialog.showToast('matchUrlPush: $pathSegment');
      }
    }
  }
}
