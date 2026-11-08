import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/models_new/history/data.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/pages/common/search/common_search_page.dart';
import 'package:PiliPlus/pages/history/widgets/item.dart';
import 'package:PiliPlus/pages/history_search/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class HistorySearchPage extends StatefulWidget {
  const HistorySearchPage({super.key});

  @override
  State<HistorySearchPage> createState() => _HistorySearchPageState();
}

class _HistorySearchPageState
    extends
        CommonSearchPageState<HistorySearchPage, HistoryData, HistoryItemModel>
    with GridMixin, RouteAware, RouteAwareMixin {
  @override
  final HistorySearchController controller = Get.put(
    HistorySearchController(),
    tag: Utils.generateRandomString(8),
  );

  /// Back from a video: the same search again, for the results as they are
  /// now (a series at the episode watched last). Its words and list stay.
  @override
  Future<void> didPopNext() async {
    super.didPopNext();
    if (controller.enableMultiSelect.value) return;
    await PlPlayerController.heartBeatsSent();
    if (!mounted || controller.enableMultiSelect.value) return;
    controller.refreshQuietly().ignore();
  }

  @override
  Widget buildList(List<HistoryItemModel> list) {
    return SliverGrid.builder(
      gridDelegate: gridDelegate,
      itemBuilder: (context, index) {
        if (index == list.length - 1) {
          controller.onLoadMore();
        }
        final item = list[index];
        return HistoryItem(
          item: item,
          ctr: controller,
          onDelete: (kid, business) =>
              controller.onDelHistory(index, kid, business),
        );
      },
      itemCount: list.length,
    );
  }
}
