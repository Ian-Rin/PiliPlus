import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonListController<R, T> extends CommonController<R, T> {
  int page = 1;
  bool isEnd = false;
  bool get endIfNullOrEmpty => true;
  bool get hasFooter => false;

  @override
  Rx<LoadingState<List<T>?>> loadingState =
      LoadingState<List<T>?>.loading().obs;

  void handleListResponse(List<T> dataList) {}

  List<T>? getDataList(R response) {
    return response as List<T>?;
  }

  void checkIsEnd(int length) {}

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading || (!isRefresh && isEnd)) return;
    // A quiet refresh that failed left the list as it was and the paging
    // at its start (a subclass's cursor too): more is then asked for as a
    // refresh, or the first page would be added a second time.
    if (!isRefresh && _quietFailed) isRefresh = true;
    isLoading = true;
    final LoadingState<R> res = await customGetData();
    if (res case Success(:final response)) {
      if (!customHandleResponse(isRefresh, res)) {
        final dataList = getDataList(response);
        if (dataList == null || dataList.isEmpty) {
          if (endIfNullOrEmpty) isEnd = true;
          if (isRefresh) {
            loadingState.value = Success(dataList);
          } else if (hasFooter) {
            loadingState.refresh();
          }
          isLoading = false;
          return;
        }
        handleListResponse(dataList);
        if (isRefresh) {
          checkIsEnd(dataList.length);
          loadingState.value = Success(dataList);
        } else if (loadingState.value case Success(:final response)) {
          response!.addAll(dataList);
          checkIsEnd(response.length);
          loadingState.refresh();
        }
      }
      page++;
      _quietFailed = false;
    } else {
      if (isRefresh && _quiet) _quietFailed = true;
      if (isRefresh &&
          !_quiet &&
          !handleError(res is Error ? res.errMsg : null)) {
        loadingState.value = res as Error;
      }
    }
    isLoading = false;
  }

  @override
  Future<void> onRefresh() {
    page = 1;
    isEnd = false;
    return super.onRefresh();
  }

  bool _quiet = false;
  bool _quietFailed = false;

  /// What makes an item the same one in a list fetched again: with it,
  /// [refreshQuietly] can put a fresh first page into a list of more pages.
  /// Null (the default): such a list is not refreshed.
  Object? quietKey(T item) => null;

  /// The first page's request, the paging left as it is. A subclass with
  /// a cursor of its own puts that aside as well.
  Future<LoadingState<R>> firstPageAgain() {
    final at = page;
    page = 1;
    try {
      return customGetData();
    } finally {
      page = at;
    }
  }

  /// A refresh the user did not ask for (the page shown again): the list
  /// is replaced in place, and a failure leaves it as it was.
  ///
  /// With more pages loaded, replacing the list would leave the first one
  /// only, and the view would jump away from where it was scrolled to. The
  /// first page is then fetched and put in front, its items taken out of
  /// the rest: what changed (a video just watched, now first) is there, and
  /// the pages below, their place and the paging stay.
  Future<void> refreshQuietly() async {
    final shown = loadingState.value.dataOrNull;
    if (page > 2 && shown != null && shown.isNotEmpty) {
      if (quietKey(shown.first) == null || isLoading) return;
      isLoading = true;
      try {
        final res = await firstPageAgain();
        if (res case Success(:final response)) {
          final fresh = getDataList(response);
          if (fresh == null ||
              fresh.isEmpty ||
              !identical(loadingState.value.dataOrNull, shown)) {
            return;
          }
          final keys = {for (final item in fresh) quietKey(item)};
          loadingState.value = Success(<T>[
            ...fresh,
            for (final item in shown)
              if (!keys.contains(quietKey(item))) item,
          ]);
        }
      } finally {
        isLoading = false;
      }
      return;
    }
    _quiet = true;
    try {
      await onRefresh();
    } finally {
      _quiet = false;
    }
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<List<T>?>.loading();
    return super.onReload();
  }
}
