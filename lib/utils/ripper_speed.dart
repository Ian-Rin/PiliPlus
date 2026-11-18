import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:thread_ripper/speed_memory.dart';

/// The download speed of the video track known from the last videos
/// ([RipperSpeedMemory], which says what it is for), kept in the settings
/// box across a restart: one for Wi-Fi, one for the mobile network.
abstract final class RipperSpeed {
  static final _memory = RipperSpeedMemory(
    load: (wifi) => GStorage.setting.get(_key(wifi))?.toString(),
    save: (wifi, value) => GStorage.setting.put(_key(wifi), value),
  );

  static String _key(bool wifi) =>
      wifi ? SettingBoxKey.ripperSpeedWifi : SettingBoxKey.ripperSpeedCellular;

  /// Whether the device is on Wi-Fi, as the video page last found.
  static set onWifi(bool value) => _memory.onWifi = value;

  /// In kbit/s; null if none was measured lately.
  static int? known() => _memory.known();

  /// A speed the proxy measured (BtrRangeProxy.onSpeed).
  static void note(int kbps, {required bool sustained}) =>
      _memory.note(kbps, sustained: sustained);
}
