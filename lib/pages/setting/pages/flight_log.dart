import 'dart:io';

import 'package:PiliPlus/utils/flight_log.dart';
import 'package:PiliPlus/utils/flight_probe.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 机上测量 (设置 → 播放器设置): what 机上模式 wrote down of the link and of
/// playback (FlightLog), as a page of numbers; the network test
/// (FlightProbe); and the ways to send both on after the flight.
class FlightLogPage extends StatefulWidget {
  const FlightLogPage({super.key});

  @override
  State<FlightLogPage> createState() => _FlightLogPageState();
}

class _FlightLogPageState extends State<FlightLogPage> {
  String _summary = '读取中…';
  final _probe = <String>[];
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String text;
    try {
      text = await FlightLog.summary();
    } catch (e) {
      text = '读取失败：$e';
    }
    if (mounted) setState(() => _summary = text);
  }

  Future<void> _runProbe() async {
    if (_probing || FlightProbe.running) return;
    setState(() {
      _probing = true;
      _probe.clear();
    });
    try {
      await FlightProbe.run(
        say: (line) {
          if (mounted) setState(() => _probe.add(line));
        },
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _probing = false);
    _load();
  }

  String get _all => [
    _summary,
    if (_probe.isNotEmpty) ...['', '刚才的网络测试：', ..._probe],
  ].join('\n');

  /// The whole record as a file with a name that shows (the record's own
  /// begins with a dot), handed to the system's share sheet.
  Future<void> _share() async {
    try {
      final lines = await FlightLog.lines();
      if (lines.isEmpty) {
        SmartDialog.showToast('还没有记录');
        return;
      }
      final now = DateTime.now();
      final name =
          'pili-flight-${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}.txt';
      final file = File(p.join((await getTemporaryDirectory()).path, name));
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          sharePositionOrigin: await ShareUtils.sharePositionOrigin,
        ),
      );
    } catch (e) {
      SmartDialog.showToast('分享失败：$e');
    }
  }

  Future<void> _clear() async {
    await FlightLog.clear();
    if (!mounted) return;
    setState(_probe.clear);
    SmartDialog.showToast('已清空');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('机上测量'),
        actions: [
          PopupMenuButton(
            itemBuilder: (_) => [
              PopupMenuItem(onTap: _load, child: const Text('刷新')),
              PopupMenuItem(
                onTap: () => Utils.copyText(_all),
                child: const Text('复制汇总'),
              ),
              PopupMenuItem(onTap: _share, child: const Text('分享完整记录')),
              PopupMenuItem(onTap: _clear, child: const Text('清空记录')),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: padding.left + 16,
          right: padding.right + 16,
          top: 12,
          bottom: padding.bottom + 100,
        ),
        children: [
          Text(
            '机上模式开着、「记录测量数据」也开着时，这里记下网络和播放的情况'
            '（每 15 秒一次小请求、每个视频的起播和卡顿、下载速度）。'
            '只存在手机里；下飞机后点右上角「复制汇总」或「分享完整记录」发出来，'
            '用来调机上模式的参数。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _probing ? null : _runProbe,
            child: Text(_probing ? '正在测，约半分钟…' : '测一下网络（约半分钟，最多用 3.5 MB 流量）'),
          ),
          if (_probe.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_probe.join('\n'), style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 16),
          Text(_summary, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
