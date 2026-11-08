import 'dart:convert';

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
import 'package:get/get.dart';

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
    if (enableSaveLastData && _showSaved()) {
      _fetchBehind();
    } else {
      queryData();
    }
  }

  /// New recommendations fetched behind the saved list shown at start: not
  /// put in until asked for ([showNew]), so that a video spotted in the
  /// saved list does not move away. Their count is shown at the top.
  final RxInt newCount = 0.obs;
  List<dynamic>? _pending;

  /// The list saved last time (the first page last fetched), shown at once
  /// as the app starts: the home page has something to browse while the
  /// new recommendations come. Not when older than a day, or from another
  /// source.
  bool _showSaved() {
    try {
      final saved =
          _savedAtStart ?? GStorage.localCache.get(LocalCacheKey.rcmdSaved);
      _savedAtStart = null;
      if (saved is! String) return false;
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['source'] != rcmdSource.index) return false;
      final at = DateTime.fromMillisecondsSinceEpoch(data['at'] as int);
      if (DateTime.now().difference(at) > const Duration(days: 1)) {
        return false;
      }
      final items = data['items'] as List;
      final List<dynamic> list = rcmdSource == RcmdSource.app
          ? VideoHttp.parseRcmdApp(items)
          : VideoHttp.parseRcmdWeb(items);
      if (list.isEmpty) return false;
      loadingState.value = Success(list);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fetchBehind() async {
    // A scroll to the saved list's end waits for this (no second page 0).
    isLoading = true;
    final LoadingState res;
    try {
      res = await customGetData();
    } finally {
      isLoading = false;
      // Even on a failure: what comes next is added below the saved list,
      // and page 0 would put the saved list in a second time (see
      // [handleListResponse]).
      page = 1;
    }
    if (isClosed) return;
    if (res case Success(:final List response) when response.isNotEmpty) {
      _pending = response;
      newCount.value = response.length;
    }
  }

  /// Puts the new recommendations above what is shown, the saved list
  /// below them past the 上次看到这里 card, and goes to the top.
  void showNew() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    newCount.value = 0;
    final shown = loadingState.value.dataOrNull ?? const [];
    if (savedRcmdTip && shown.isNotEmpty) lastRefreshAt = pending.length;
    loadingState.value = Success([
      ...pending,
      ...shown.length > 200 ? shown.take(50) : shown,
    ]);
    scrollController.jumpToTop();
  }

  @override
  Future<LoadingState> customGetData() {
    if (page == 0) {
      if (_takeEarly(rcmdSource) case final early?) return early;
    }
    return _fetch(rcmdSource, page);
  }

  static Future<LoadingState> _fetch(RcmdSource source, int page) {
    // The first page's items as they came, saved for the next start.
    final raw = page == 0 && Pref.enableSaveLastData ? <Object?>[] : null;
    final Future<LoadingState> result = switch (source) {
      RcmdSource.app => VideoHttp.rcmdVideoListApp(
        freshIdx: page,
        keepRaw: raw,
      ),
      // 桌面端：与官方 Windows 客户端一致，每次请求 30 条
      RcmdSource.desktop => VideoHttp.rcmdVideoList(
        freshIdx: page,
        ps: 30,
        desktop: true,
        keepRaw: raw,
      ),
      RcmdSource.web => VideoHttp.rcmdVideoList(
        freshIdx: page,
        ps: 20,
        keepRaw: raw,
      ),
    };
    if (raw != null) {
      result.then((res) {
        if (res is Success && raw.isNotEmpty) _save(source, raw);
      }).ignore();
    }
    return result;
  }

  static void _save(RcmdSource source, List<Object?> items) {
    try {
      GStorage.localCache.put(
        LocalCacheKey.rcmdSaved,
        jsonEncode({
          'source': source.index,
          'at': DateTime.now().millisecondsSinceEpoch,
          'items': items,
        }),
      );
    } catch (_) {}
  }

  static ({RcmdSource source, DateTime at, Future<LoadingState> result})?
  _early;

  /// The list saved last time, as it was when the app started: the early
  /// request ([startEarly]) may come back, and save its own, before the
  /// home page is built.
  static Object? _savedAtStart;

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
    // Read before the request below saves its answer over it.
    _savedAtStart = GStorage.localCache.get(LocalCacheKey.rcmdSaved);
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
    // The new ones are here already, fetched a moment ago.
    if (_pending != null) {
      showNew();
      return Future.value();
    }
    page = 0;
    isEnd = false;
    return queryData();
  }

  void toTopAndRefresh() {
    scrollController.jumpToTop();
    showRefresh();
  }
}
