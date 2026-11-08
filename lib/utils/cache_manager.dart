import 'dart:io' show Directory, File, HttpClient, HttpHeaders;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<Directory> _cacheDirectoryProvider() async {
  final tmpDirPath = await PathProviderPlatform.instance.getTemporaryPath();
  if (tmpDirPath == null) {
    throw MissingPlatformDirectoryException(
      'Unable to get temporary directory',
    );
  }
  if (PlatformUtils.isDesktop) {
    return Directory(path.join(tmpDirPath, Constants.appName));
  }
  return Directory(tmpDirPath);
}

abstract final class CacheManager {
  static late final DefaultCacheManager manager;

  /// The images' client. The library's own (http's default) let an idle
  /// connection go after 15 s: a scroll after a pause, or the covers of a
  /// page opened a little later, waited for a new TCP and TLS round to the
  /// image CDN (from abroad, a few hundred milliseconds each). Shared with
  /// [warmImageHosts].
  static final HttpClient _imageHttp = HttpClient()
    ..idleTimeout = const Duration(seconds: 60);

  static Future<void> ensureInitialized() => DefaultCacheManager.init(
    maxNrOfCacheLength: Pref.maxCacheSize.toInt(),
    cacheDirectoryProvider: _cacheDirectoryProvider,
    httpClientFactory: () => IOClient(_imageHttp),
  ).then((i) => manager = i);

  /// Bilibili's covers and avatars come from these.
  static const _imageHosts = ['i0.hdslb.com', 'i1.hdslb.com', 'i2.hdslb.com'];

  /// Opens a connection to each image host as the app starts, while the
  /// home page's recommendations are on their way: their covers then go
  /// out at once. A HEAD of the root, answered at once.
  static void warmImageHosts() {
    for (final host in _imageHosts) {
      () async {
        try {
          final request = await _imageHttp.headUrl(Uri.https(host, '/'));
          request.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
          final response = await request.close().timeout(
            const Duration(seconds: 6),
          );
          await response.drain<void>();
        } catch (_) {}
      }();
    }
  }

  // 获取缓存目录
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> loadApplicationCache() async {
    try {
      if (PlatformUtils.isDesktop) {
        return manager.getTotalLength();
      }

      final Directory tempDirectory = await getTemporaryDirectory();
      if (tempDirectory.existsSync()) {
        return await getTotalSizeOfFilesInDir(tempDirectory);
      }
    } catch (_) {}
    return 0;
  }

  // 循环计算文件的大小
  @pragma('vm:notify-debugger-on-exception')
  static Future<int> getTotalSizeOfFilesInDir(Directory file) async {
    int total = 0;
    await for (final child in file.list(recursive: false)) {
      if (child is File) {
        total += await child.length();
      } else if (child is Directory) {
        if (path.equals(child.path, manager.cacheDir)) {
          total += manager.getTotalLength();
        } else {
          await for (final i in child.list(recursive: true)) {
            if (i is File) {
              total += await i.length();
            }
          }
        }
      }
    }
    return total;
  }

  // 清除 Library/Caches 目录及文件缓存
  @pragma('vm:notify-debugger-on-exception')
  static Future<void> clearLibraryCache() async {
    try {
      await manager.emptyCache();
      if (PlatformUtils.isDesktop) return;

      final tempDirectory = await getTemporaryDirectory();
      if (tempDirectory.existsSync()) {
        await for (final file in tempDirectory.list(recursive: false)) {
          if (file is Directory && path.equals(file.path, manager.cacheDir)) {
            continue;
          }
          await file.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}
