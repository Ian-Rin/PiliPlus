import 'package:PiliPlus/common/widgets/appbar/appbar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_insets_safe_area.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/common/search/common_search_controller.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonSearchPageState<S extends StatefulWidget, R, T>
    extends State<S> {
  CommonSearchController<R, T> get controller;

  List<Widget>? get extraActions => null;

  List<Widget>? get multiSelectActions => null;

  @override
  Widget build(BuildContext context) {
    if (controller case final MultiSelectBase multiCtr) {
      return Obx(() {
        final enableMultiSelect = multiCtr.enableMultiSelect.value;
        return popScope(
          canPop: !enableMultiSelect,
          onPopInvokedWithResult: (didPop, result) {
            if (enableMultiSelect) {
              multiCtr.handleSelect();
            }
          },
          child: _build(true),
        );
      });
    }
    return _build(false);
  }

  Widget _build(bool multiSelect) {
    return SimpleScaffold(
      appBar: _buildBar(multiSelect),
      body: ViewInsetsSafeArea(
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: controller.scrollController,
          slivers: [
            ViewSliverSafeArea(
              sliver: Obx(() => _buildBody(controller.loadingState.value)),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildBar(bool multiSelect) {
    final AppBar bar = AppBar(
      actions: [
        IconButton(
          tooltip: '搜索',
          onPressed: controller.onRefresh,
          icon: const Icon(Icons.search_outlined, size: 22),
        ),
        ...?extraActions,
        const SizedBox(width: 10),
      ],
      title: TextField(
        autofocus: true,
        focusNode: controller.focusNode,
        controller: controller.editController,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: '搜索',
          visualDensity: .standard,
          border: InputBorder.none,
          suffixIcon: IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.clear, size: 22),
            onPressed: () => controller
              ..loadingState.value = LoadingState.loading()
              ..onClear()
              ..focusNode.requestFocus(),
          ),
        ),
        onSubmitted: (value) => controller.onRefresh(),
      ),
    );
    if (multiSelect) {
      return MultiSelectAppBarWidget(
        ctr: controller as MultiSelectBase,
        actions: multiSelectActions,
        child: bar,
      );
    }
    return bar;
  }

  Widget _buildBody(LoadingState<List<T>?> loadingState) {
    return switch (loadingState) {
      Loading() when controller.wordsKey != null => _buildWords(),
      Loading() => const HttpError(),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? buildList(response)
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget buildList(List<T> list);

  /// The words searched here before (see [CommonSearchController.wordsKey]):
  /// a tap searches again, a long press removes one.
  Widget _buildWords() {
    final words = controller.words;
    if (words.isEmpty) return const HttpError();
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.secondary;
    return SliverPadding(
      padding: const .fromLTRB(16, 8, 10, 25),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                Text(
                  '搜索历史',
                  style: theme.textTheme.titleMedium!.copyWith(
                    fontWeight: .bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  style: const ButtonStyle(
                    visualDensity: .compact,
                    tapTargetSize: .shrinkWrap,
                  ),
                  onPressed: controller.onClearWords,
                  icon: Icon(
                    Icons.clear_all_outlined,
                    size: 18,
                    color: secondary,
                  ),
                  label: Text('清空', style: TextStyle(color: secondary)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const .only(right: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final word in words)
                    SearchText(
                      text: word,
                      onTap: controller.onSearchWord,
                      onLongPress: controller.onRemoveWord,
                      fontSize: 14,
                      maxLines: 1,
                      overflow: .ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
