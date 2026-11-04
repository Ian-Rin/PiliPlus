import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonSearchController<R, T> extends CommonListController<R, T> {
  final editController = TextEditingController();
  final focusNode = FocusNode();

  /// Where this page keeps the words searched on it, in the box the main
  /// search keeps its own in; null keeps none. Shown while the box is empty,
  /// and recorded like the main search's (its 记录搜索历史 switch).
  String? get wordsKey => null;

  late final words = List<String>.from(
    (wordsKey == null ? null : GStorage.historyWord.get(wordsKey)) ??
        const <String>[],
  ).obs;

  static const _maxWords = 30;

  void _saveWords() {
    if (wordsKey case final key?) {
      GStorage.historyWord.put(key, words.toList());
    }
  }

  void _remember(String word) {
    if (wordsKey == null || word.isEmpty || !Pref.recordSearchHistory) return;
    if (words.firstOrNull == word) return;
    words
      ..remove(word)
      ..insert(0, word);
    if (words.length > _maxWords) words.removeRange(_maxWords, words.length);
    _saveWords();
  }

  void onSearchWord(String word) {
    editController.value = TextEditingValue(
      text: word,
      selection: TextSelection.collapsed(offset: word.length),
    );
    focusNode.unfocus();
    onRefresh();
  }

  void onRemoveWord(String word) {
    words.remove(word);
    _saveWords();
  }

  void onClearWords() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('确定清空搜索历史？'),
      onConfirm: () {
        words.clear();
        if (wordsKey case final key?) GStorage.historyWord.delete(key);
      },
    );
  }

  void onClear() {
    if (editController.text.isNotEmpty) {
      editController.clear();
    } else {
      Get.back();
    }
  }

  @override
  Future<void> onRefresh() {
    if (editController.value.text.isEmpty) {
      return Future.syncValue(null);
    }
    _remember(editController.value.text.trim());
    return super.onRefresh();
  }

  @override
  void onClose() {
    editController.dispose();
    focusNode.dispose();
    super.onClose();
  }
}
