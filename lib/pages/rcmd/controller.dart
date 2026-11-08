import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/home_tab_type.dart';
import 'package:PiliPlus/models/common/rcmd_source.dart';
import 'package:PiliPlus/pages/common/common_controller.dart'
    show RefreshImplMixin;
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';

class RcmdController extends CommonListController with RefreshImplMixin {
  late bool enableSaveLastData = Pref.enableSaveLastData;

  /// 可在设置页切换后立即生效，无需重启
  RcmdSource rcmdSource = Pref.rcmdSource;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  @override
  bool get isEnd => false;

  @override
  void onInit() {
    super.onInit();
    page = 0;
    queryData();
  }

  @override
  Future<LoadingState> customGetData() {
    if (page == 0) {
      if (_takeEarly(rcmdSource) case final early?) return early;
    }
    return _fetch(rcmdSource, page);
  }

  static Future<LoadingState> _fetch(RcmdSource source, int page) {
    return switch (source) {
      RcmdSource.app => VideoHttp.rcmdVideoListApp(freshIdx: page),
      // 桌面端：与官方 Windows 客户端一致，每次请求 30 条
      RcmdSource.desktop => VideoHttp.rcmdVideoList(
        freshIdx: page,
        ps: 30,
        desktop: true,
      ),
      RcmdSource.web => VideoHttp.rcmdVideoList(freshIdx: page, ps: 20),
    };
  }

  static ({RcmdSource source, DateTime at, Future<LoadingState> result})?
  _early;

  /// The home page's first recommendations, asked for as the app starts
  /// (once the accounts are in), not once the home page is built: the
  /// request is the home page's whole wait, and the setup before the first
  /// frame (storage, services, the first build) runs meanwhile. Only when
  /// the recommendations are a home tab (the one shown first then).
  static void startEarly() {
    final tabs = GStorage.setting.get(SettingBoxKey.tabBarSort) as List?;
    if (tabs != null && !tabs.contains(HomeTabType.rcmd.index)) return;
    final source = Pref.rcmdSource;
    final at = DateTime.now();
    final result = _fetch(source, 0)
      ..then((res) {
        // A slow one in the logs (设置 → 日志), to see where the wait is.
        final ms = DateTime.now().difference(at).inMilliseconds;
        if (ms >= 1500) {
          Utils.reportError(
            '[主页加载] 推荐（${source.name}）${ms}ms 才回来，启动时就已发出'
            '${res is Success ? '' : '，失败：${(res as Error).errMsg}'}',
          );
        }
      }).ignore();
    _early = (source: source, at: at, result: result);
  }

  static Future<LoadingState>? _takeEarly(RcmdSource source) {
    final early = _early;
    _early = null;
    if (early == null ||
        early.source != source ||
        DateTime.now().difference(early.at) > const Duration(seconds: 30)) {
      return null;
    }
    return early.result;
  }

  @override
  bool handleError(String? errMsg) {
    return enableSaveLastData;
  }

  @override
  void handleListResponse(List dataList) {
    if (enableSaveLastData && page == 0) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          if (savedRcmdTip) {
            lastRefreshAt = dataList.length;
          }
          if (response.length > 200) {
            dataList.addAll(response.take(50));
          } else {
            dataList.addAll(response);
          }
        }
      }
    }
  }

  @override
  Future<void> onRefresh() {
    page = 0;
    isEnd = false;
    return queryData();
  }

  void toTopAndRefresh() {
    scrollController.jumpToTop();
    showRefresh();
  }
}
