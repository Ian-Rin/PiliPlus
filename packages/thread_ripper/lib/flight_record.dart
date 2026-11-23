// The record the app keeps of a flight (its 机上模式's 测量记录), read back
// into a page of numbers: what the link did, and what playback made of it.
//
// The mode's figures (how long a start may take, when a picture is given
// up, how far ahead to download, how many connections) were set from two
// passengers' reports. This is what replaces them with the link's own.
//
// One line an event, `HH:mm:ss kind key=value ...`, written by the app
// (FlightLog) and read here; a line starting with `#` begins a day
// (`# 2026-12-01 ...`). The kinds:
//   hb 712 | hb x          a small request every 15 s: its time in ms, or
//                          that it failed (the link was gone)
//   open q= so= px= kb=    a video opened: quality, sound alone, through
//                          the proxy, bitrate of picture and sound (kbit/s)
//   first ms= open=        its first moving picture, from the press and
//                          from the player being given it
//   play ms=               it plays (its sound alone too), from the press,
//                          to the second
//   s pos= buf= w= idle= rx= gone=   every 10 s of a video: position and
//                          seconds downloaded ahead, waiting on the
//                          download, the player's cache full, what came in
//                          (kbit/s), seconds since the last byte
//   stall ms= gone= pos=   playback waited that long, so many seconds of
//                          it with nothing arriving
//   seek ms= gone= pos=    the same, after the viewer moved the playhead
//   px req= err= to= cut= fb=p50/p90/max sil= kb=   the proxy's requests
//                          of a minute: made, failed, timed out, cut off as
//                          the slower copy, time to first byte, longest
//                          silence while downloading, KiB received
//   api n= err= ms=p50/p90 the app's own requests of a minute
//   ev name key=value      giveup (the picture), raise and down (a
//                          quality above the lowest, and back), broke (a
//                          stream, opened again), gaveup (the proxy, on a
//                          piece), bg, fg, on, off
//   probe key=value        the network test's results

/// See the head of this file.
abstract final class FlightRecord {
  /// `HH:mm:ss` of [at].
  static String clock(DateTime at) =>
      '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}';

  /// The line that begins a day's record.
  static String day(DateTime at, [String note = '']) =>
      '# ${at.year}-${_two(at.month)}-${_two(at.day)}'
      '${note.isEmpty ? '' : ' $note'}';

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  /// A line of [kind] at [at], with [fields] in the order given.
  static String line(
    DateTime at,
    String kind, [
    Map<String, Object?> fields = const {},
  ]) {
    final buffer = StringBuffer('${clock(at)} $kind');
    for (final MapEntry(:key, :value) in fields.entries) {
      if (value == null) continue;
      final text = value is bool ? (value ? '1' : '0') : '$value';
      // A value is one word: what separates fields must not be in it.
      buffer.write(' $key=${text.replaceAll(RegExp(r'\s+'), '_')}');
    }
    return buffer.toString();
  }

  /// [sorted]'s value at [fraction] of the way up (0 to 1).
  static int percentile(List<int> sorted, double fraction) {
    if (sorted.isEmpty) return 0;
    final at = ((sorted.length - 1) * fraction).round();
    return sorted[at.clamp(0, sorted.length - 1)];
  }

  /// `p50/p90/max` of [values], unsorted.
  static String spread(List<int> values) {
    if (values.isEmpty) return '0/0/0';
    final sorted = List.of(values)..sort();
    return '${percentile(sorted, 0.5)}/${percentile(sorted, 0.9)}'
        '/${sorted.last}';
  }

  /// What [lines] say, as a page to read (and to send on).
  static String summary(Iterable<String> lines) =>
      _Summary().read(lines).toString();
}

class _Line {
  _Line(this.at, this.kind, this.words);

  /// Seconds since the first day's midnight.
  final int at;
  final String kind;
  final List<String> words;

  String? field(String key) {
    for (final word in words) {
      if (word.startsWith('$key=')) return word.substring(key.length + 1);
    }
    return null;
  }

  int? number(String key) => int.tryParse(field(key) ?? '');
}

class _Summary {
  final _days = <String>[];
  int _lines = 0;
  int? _from, _to;

  // The link, by the heartbeat.
  final _hbMs = <int>[];
  int _hbFailed = 0;
  final _outages = <int>[];
  int? _outageFrom;
  int? _hbLast;
  final _between = <int>[];
  int? _okSince;

  // Playback.
  int _opened = 0, _raised = 0, _soundOnly = 0, _direct = 0;
  final _firstMs = <int>[];
  final _playMs = <int>[];
  final _stallMs = <int>[];
  final _seekMs = <int>[];
  int _stallGone = 0;
  int _samples = 0, _waiting = 0;
  final _rx = <int>[];
  final _ahead = <int>[];
  final _events = <String, int>{};

  // The proxy and the API.
  int _req = 0, _err = 0, _timeouts = 0, _cut = 0, _kib = 0;
  final _fb50 = <int>[];
  final _fb90 = <int>[];
  int _fbMax = 0, _silence = 0;
  int _api = 0, _apiErr = 0;
  final _api50 = <int>[];
  final _api90 = <int>[];

  final _probes = <String>[];

  /// A heartbeat later than this after the one before was not the next
  /// one: the app was away, and what the link did meanwhile is not known.
  static const _hbGap = 50;

  _Summary read(Iterable<String> lines) {
    var day = 0;
    int? last;
    DateTime? firstDate;
    for (final raw in lines) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('#')) {
        final said = text.substring(1).trim();
        _days.add(said);
        // The day it names, counted from the first one named: the lines
        // after it carry the time of day alone.
        final named = DateTime.tryParse(said.split(' ').first);
        if (named != null) {
          // In UTC: a day an hour short (summer time) is still a day.
          final date = DateTime.utc(named.year, named.month, named.day);
          firstDate ??= date;
          day = date.difference(firstDate).inDays;
          last = null;
        }
        continue;
      }
      final words = text.split(' ');
      if (words.length < 2) continue;
      final clock = words[0].split(':');
      if (clock.length != 3) continue;
      final h = int.tryParse(clock[0]);
      final m = int.tryParse(clock[1]);
      final s = int.tryParse(clock[2]);
      if (h == null || m == null || s == null) continue;
      var at = day * 86400 + h * 3600 + m * 60 + s;
      // Past midnight within a record.
      if (last != null && at < last - 3600) {
        day++;
        at += 86400;
      }
      last = at;
      _lines++;
      _from ??= at;
      _to = at;
      _take(_Line(at, words[1], words.sublist(2)));
    }
    _endOutage(null);
    return this;
  }

  void _take(_Line line) {
    switch (line.kind) {
      case 'hb':
        _heartbeat(line);
      case 'open':
        _opened++;
        if (line.field('so') == '1') _soundOnly++;
        if (line.field('px') == '0') _direct++;
      case 'first':
        if (line.number('ms') case final ms?) _firstMs.add(ms);
      case 'play':
        if (line.number('ms') case final ms?) _playMs.add(ms);
      case 's':
        _samples++;
        final waiting = line.field('w') == '1';
        if (waiting) _waiting++;
        final rx = line.number('rx');
        // What the link does shows while the player still takes all that
        // comes; with its cache full, what comes in is what it plays.
        if (rx != null && rx > 0 && line.field('idle') == '0') _rx.add(rx);
        if (line.number('buf') case final ahead? when !waiting) {
          _ahead.add(ahead);
        }
      case 'stall':
        if (line.number('ms') case final ms?) _stallMs.add(ms);
        _stallGone += line.number('gone') ?? 0;
      case 'seek':
        if (line.number('ms') case final ms?) _seekMs.add(ms);
      case 'px':
        _req += line.number('req') ?? 0;
        _err += line.number('err') ?? 0;
        _timeouts += line.number('to') ?? 0;
        _cut += line.number('cut') ?? 0;
        _kib += line.number('kb') ?? 0;
        final silence = line.number('sil') ?? 0;
        if (silence > _silence) _silence = silence;
        final parts = (line.field('fb') ?? '').split('/');
        if (parts.length == 3) {
          final p50 = int.tryParse(parts[0]) ?? 0;
          final p90 = int.tryParse(parts[1]) ?? 0;
          final most = int.tryParse(parts[2]) ?? 0;
          if (p50 > 0) _fb50.add(p50);
          if (p90 > 0) _fb90.add(p90);
          if (most > _fbMax) _fbMax = most;
        }
      case 'api':
        _api += line.number('n') ?? 0;
        _apiErr += line.number('err') ?? 0;
        final parts = (line.field('ms') ?? '').split('/');
        if (parts.length == 2) {
          final p50 = int.tryParse(parts[0]) ?? 0;
          final p90 = int.tryParse(parts[1]) ?? 0;
          if (p50 > 0) _api50.add(p50);
          if (p90 > 0) _api90.add(p90);
        }
      case 'ev':
        if (line.words.isNotEmpty) {
          _events.update(line.words.first, (n) => n + 1, ifAbsent: () => 1);
          if (line.words.first == 'raise') _raised++;
        }
      case 'probe':
        _probes.add(line.words.join(' '));
    }
  }

  void _heartbeat(_Line line) {
    final before = _hbLast;
    // The app was away: an outage it was in is of unknown length.
    if (before != null && line.at - before > _hbGap) {
      _outageFrom = null;
      _okSince = null;
    }
    _hbLast = line.at;
    final ms = line.words.isEmpty ? null : int.tryParse(line.words.first);
    if (ms == null) {
      _hbFailed++;
      if (_outageFrom == null) {
        _outageFrom = before != null && line.at - before <= _hbGap
            ? before
            : line.at;
        if (_okSince case final since?) _between.add(_outageFrom! - since);
        _okSince = null;
      }
      return;
    }
    _hbMs.add(ms);
    _endOutage(line.at);
    _okSince ??= line.at;
  }

  void _endOutage(int? at) {
    final from = _outageFrom;
    if (from == null) return;
    _outageFrom = null;
    // Still gone as the record ends: its length is not known.
    if (at != null) _outages.add(at - from);
  }

  static String _span(int seconds) {
    if (seconds < 90) return '$seconds 秒';
    if (seconds < 5400) return '${(seconds / 60).toStringAsFixed(1)} 分钟';
    return '${(seconds / 3600).toStringAsFixed(1)} 小时';
  }

  static String _percent(int part, int whole) =>
      whole == 0 ? '0%' : '${(part * 100 / whole).toStringAsFixed(1)}%';

  static int _median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = List.of(values)..sort();
    return FlightRecord.percentile(sorted, 0.5);
  }

  @override
  String toString() {
    final out = <String>[];
    final span = (_to ?? 0) - (_from ?? 0);
    out.add(
      '机上测量汇总：$_lines 行，跨 ${_span(span)}'
      '${_days.isEmpty ? '' : '，${_days.first}'}',
    );

    final beats = _hbMs.length + _hbFailed;
    if (beats == 0) {
      out.add('链路：没有心跳记录');
    } else {
      final sorted = List.of(_hbMs)..sort();
      out.add(
        '链路（每 15 秒一次小请求，共 $beats 次）：'
        '失败 ${_percent(_hbFailed, beats)}；'
        '往返 最小 ${sorted.isEmpty ? 0 : sorted.first}'
        ' / 中位 ${FlightRecord.percentile(sorted, 0.5)}'
        ' / 九成 ${FlightRecord.percentile(sorted, 0.9)}'
        ' / 最大 ${sorted.isEmpty ? 0 : sorted.last} 毫秒',
      );
      if (_outages.isEmpty) {
        out.add('断网：没有记到一次完整的');
      } else {
        final lengths = List.of(_outages)..sort();
        out.add(
          '断网：${lengths.length} 次，'
          '中位 ${_span(FlightRecord.percentile(lengths, 0.5))}，'
          '九成 ${_span(FlightRecord.percentile(lengths, 0.9))}，'
          '最长 ${_span(lengths.last)}，'
          '合计 ${_span(lengths.fold(0, (a, b) => a + b))}'
          '${_between.isEmpty ? '' : '；两次之间连着通的时间中位 ${_span(_median(_between))}'}',
        );
      }
    }

    if (_opened == 0 && _samples == 0) {
      out.add('播放：没有记录');
    } else {
      out.add(
        '播放：打开 $_opened 个视频'
        '（升一档 $_raised，只放声音 $_soundOnly，不走代理 $_direct）',
      );
      if (_firstMs.isNotEmpty) {
        final sorted = List.of(_firstMs)..sort();
        out.add(
          '起播：${sorted.length} 次，'
          '中位 ${(FlightRecord.percentile(sorted, 0.5) / 1000).toStringAsFixed(1)}'
          ' / 九成 ${(FlightRecord.percentile(sorted, 0.9) / 1000).toStringAsFixed(1)}'
          ' / 最长 ${(sorted.last / 1000).toStringAsFixed(1)} 秒',
        );
      }
      if (_playMs.isNotEmpty) {
        final sorted = List.of(_playMs)..sort();
        out.add(
          '开始播放（含只放声音，精确到秒）：${sorted.length} 次，'
          '中位 ${(FlightRecord.percentile(sorted, 0.5) / 1000).toStringAsFixed(0)}'
          ' / 九成 ${(FlightRecord.percentile(sorted, 0.9) / 1000).toStringAsFixed(0)}'
          ' / 最长 ${(sorted.last / 1000).toStringAsFixed(0)} 秒',
        );
      }
      if (_stallMs.isEmpty) {
        out.add('卡顿：没有');
      } else {
        final sorted = List.of(_stallMs)..sort();
        final total = sorted.fold(0, (a, b) => a + b) ~/ 1000;
        out.add(
          '卡顿：${sorted.length} 次，共 ${_span(total)}'
          '（其中断网 ${_span(_stallGone)}），'
          '中位 ${(FlightRecord.percentile(sorted, 0.5) / 1000).toStringAsFixed(1)}'
          ' / 最长 ${(sorted.last / 1000).toStringAsFixed(1)} 秒；'
          '采样里在等下载的占 ${_percent(_waiting, _samples)}',
        );
      }
      if (_seekMs.isNotEmpty) {
        final sorted = List.of(_seekMs)..sort();
        out.add(
          '跳转后等待：${sorted.length} 次，'
          '中位 ${(FlightRecord.percentile(sorted, 0.5) / 1000).toStringAsFixed(1)}'
          ' / 最长 ${(sorted.last / 1000).toStringAsFixed(1)} 秒',
        );
      }
      if (_rx.isNotEmpty) {
        final sorted = List.of(_rx)..sort();
        out.add(
          '下载速度（播放器还在要数据时，每 10 秒一个，共 ${sorted.length} 个）：'
          '一成 ${FlightRecord.percentile(sorted, 0.1)}'
          ' / 中位 ${FlightRecord.percentile(sorted, 0.5)}'
          ' / 九成 ${FlightRecord.percentile(sorted, 0.9)}'
          ' / 最大 ${sorted.last} kbit/s',
        );
      }
      if (_ahead.isNotEmpty) {
        final sorted = List.of(_ahead)..sort();
        out.add(
          '提前缓冲（没在等的时候）：'
          '一成 ${FlightRecord.percentile(sorted, 0.1)}'
          ' / 中位 ${FlightRecord.percentile(sorted, 0.5)}'
          ' / 最大 ${sorted.last} 秒',
        );
      }
    }

    if (_req > 0) {
      out.add(
        '代理请求：$_req 个，失败 ${_percent(_err, _req)}'
        '（超时 $_timeouts），因重复被取消 $_cut；'
        '首字节 中位 ${_median(_fb50)} / 九成 ${_median(_fb90)}'
        ' / 最大 $_fbMax 毫秒；'
        '下载中最长静默 ${(_silence / 1000).toStringAsFixed(1)} 秒；'
        '共收 ${(_kib / 1024).toStringAsFixed(1)} MiB',
      );
    }
    if (_api > 0) {
      out.add(
        '接口请求：$_api 个，失败 ${_percent(_apiErr, _api)}；'
        '中位 ${_median(_api50)} / 九成 ${_median(_api90)} 毫秒',
      );
    }
    if (_events.isNotEmpty) {
      const names = {
        'giveup': '放弃画面',
        'raise': '升一档',
        'down': '升档后退回',
        'broke': '断流重开',
        'gaveup': '代理放弃',
        'bg': '切到后台',
        'fg': '回到前台',
        'on': '开机上模式',
        'off': '关机上模式',
      };
      out.add(
        '事件：${[
          for (final MapEntry(:key, :value) in _events.entries) '${names[key] ?? key} $value',
        ].join('，')}',
      );
    }
    for (final probe in _probes) {
      out.add('网络测试：$probe');
    }
    return out.join('\n');
  }
}
