import 'package:test/test.dart';
import 'package:thread_ripper/flight_record.dart';
import 'package:thread_ripper/link_speed.dart';

void main() {
  group('RipperLinkSpeed', () {
    final t0 = DateTime(2026, 12, 1, 12);
    DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

    test('nothing is carried until enough was measured', () {
      final speed = RipperLinkSpeed();
      expect(speed.carries(600000, now: t0), isFalse);
      for (var i = 0; i < 3; i++) {
        speed.note(3000, now: at(i * 10));
      }
      expect(speed.median(now: at(30)), isNull);
      expect(speed.carries(600000, now: at(30)), isFalse);
      speed.note(3000, now: at(30));
      expect(speed.median(now: at(31)), 3000);
      expect(speed.carries(600000, now: at(31)), isTrue);
    });

    test('three times the bitrate, by the median', () {
      final speed = RipperLinkSpeed();
      for (final (i, kbps) in [2000, 2100, 1900, 2000].indexed) {
        speed.note(kbps, now: at(i * 10));
      }
      // 660 kbit/s of picture and sound need 1980.
      expect(speed.carries(660000, now: at(40)), isTrue);
      expect(speed.carries(700000, now: at(40)), isFalse);
      // A stream that states no bitrate is not started on.
      expect(speed.carries(0, now: at(40)), isFalse);
    });

    test('a window that straddled an outage, or a burst, does not move it', () {
      final speed = RipperLinkSpeed();
      for (final (i, kbps) in [3000, 3100, 40, 2900, 9000, 3000].indexed) {
        speed.note(kbps, now: at(i * 10));
      }
      expect(speed.median(now: at(60)), 3000);
    });

    test('what was measured long ago is not the link now', () {
      final speed = RipperLinkSpeed();
      for (var i = 0; i < 6; i++) {
        speed.note(3000, now: at(i * 10));
      }
      expect(speed.carries(600000, now: at(9 * 60)), isTrue);
      // The first of them are ten minutes old: four are left, then three.
      expect(speed.carries(600000, now: at(10 * 60 + 20)), isTrue);
      expect(speed.carries(600000, now: at(10 * 60 + 31)), isFalse);
    });

    test('a raise taken back is not tried again for ten minutes', () {
      final speed = RipperLinkSpeed();
      for (var i = 0; i < 6; i++) {
        speed.note(3000, now: at(i * 10));
      }
      speed.failed(now: at(60));
      // Forgotten, and measured anew.
      for (var i = 0; i < 6; i++) {
        speed.note(3000, now: at(70 + i * 10));
      }
      expect(speed.median(now: at(130)), 3000);
      expect(speed.carries(600000, now: at(130)), isFalse);
      expect(speed.carries(600000, now: at(60 + 10 * 60 - 1)), isFalse);
      expect(speed.carries(600000, now: at(60 + 10 * 60 + 1)), isTrue);
    });
  });

  group('FlightRecord', () {
    test('a line: fields in order, a value one word', () {
      expect(
        FlightRecord.line(DateTime(2026, 12, 1, 9, 5, 3), 'open', {
          'q': 16,
          'up': false,
          'so': true,
          'skipped': null,
          'note': 'two words',
        }),
        '09:05:03 open q=16 up=0 so=1 note=two_words',
      );
      expect(FlightRecord.day(DateTime(2026, 12, 1), 'v1'), '# 2026-12-01 v1');
      expect(FlightRecord.spread([5, 1, 9, 3]), '5/9/9');
      expect(FlightRecord.spread([]), '0/0/0');
    });

    test('the link by its heartbeat: outages and their lengths', () {
      final text = FlightRecord.summary([
        '# 2026-12-01 v1',
        '12:00:00 hb 700',
        '12:00:15 hb 650',
        '12:00:30 hb x',
        '12:00:45 hb x',
        '12:01:00 hb 800',
        '12:01:15 hb 720',
        // The app was away for ten minutes: not an outage.
        '12:11:15 hb 690',
        '12:11:30 hb x',
        '12:11:45 hb 710',
      ]);
      expect(text, contains('共 9 次'));
      expect(text, contains('失败 33.3%'));
      expect(text, contains('最小 650'));
      // From the last one that answered to the next: 45 s, then 30 s.
      expect(text, contains('断网：2 次'));
      expect(text, contains('最长 45 秒'));
      expect(text, contains('合计 75 秒'));
    });

    test(
      'an outage the record ends in, or the app left in, is not counted',
      () {
        final text = FlightRecord.summary([
          '# 2026-12-01',
          '12:00:00 hb 700',
          '12:00:15 hb x',
          '12:10:00 hb 700',
          '12:10:15 hb x',
        ]);
        expect(text, contains('断网：没有记到一次完整的'));
      },
    );

    test('playback, the proxy, the API, and what happened', () {
      final text = FlightRecord.summary([
        '# 2026-12-01',
        '23:59:40 open q=16 so=0 px=1 kb=364',
        '23:59:49 first ms=9000',
        '23:59:50 play ms=10000',
        '23:59:50 s pos=1 buf=20 w=0 idle=0 rx=1200 gone=0',
        // Past midnight.
        '00:00:00 s pos=11 buf=90 w=0 idle=0 rx=1000 gone=0',
        '00:00:10 s pos=21 buf=600 w=0 idle=1 rx=300 gone=8',
        '00:00:20 s pos=21 buf=0 w=1 idle=0 rx=0 gone=12',
        '00:00:32 stall ms=12000 gone=9',
        '00:00:40 px req=40 err=4 to=3 cut=1 fb=700/1500/4000 sil=9000 kb=2048',
        '00:00:40 api n=5 err=1 ms=900/2500',
        '00:00:50 seek ms=4000 gone=0 pos=300',
        '00:01:00 ev raise q=32 kbps=2900 kb=600',
        '00:01:00 open q=32 so=0 px=1 kb=664',
        '00:01:05 first ms=5000',
        '00:01:30 ev down q=16',
        '00:02:00 ev giveup wait=20',
        '00:02:01 open q=16 so=1 px=1 kb=64',
        '00:03:00 probe tcp=3/4/3 rtt=640/700/910',
      ]);
      expect(text, contains('跨 3.3 分钟'));
      expect(text, contains('打开 3 个视频（升一档 1，只放声音 1，不走代理 0）'));
      expect(text, contains('起播：2 次，中位 9.0 / 九成 9.0 / 最长 9.0 秒'));
      expect(text, contains('开始播放（含只放声音，精确到秒）：1 次，中位 10'));
      expect(text, contains('卡顿：1 次，共 12 秒（其中断网 9 秒）'));
      expect(text, contains('在等下载的占 25.0%'));
      expect(text, contains('跳转后等待：1 次，中位 4.0 / 最长 4.0 秒'));
      // Only while the player still took all that came.
      expect(text, contains('共 2 个）：一成 1000 / 中位 1200'));
      expect(text, contains('代理请求：40 个，失败 10.0%（超时 3），因重复被取消 1'));
      expect(text, contains('首字节 中位 700 / 九成 1500 / 最大 4000 毫秒'));
      expect(text, contains('最长静默 9.0 秒'));
      expect(text, contains('共收 2.0 MiB'));
      expect(text, contains('接口请求：5 个，失败 20.0%；中位 900 / 九成 2500 毫秒'));
      expect(text, contains('升一档 1，升档后退回 1'));
      expect(text, contains('放弃画面 1'));
      expect(text, contains('网络测试：tcp=3/4/3 rtt=640/700/910'));
    });

    test('lines that are not the record are passed over', () {
      final text = FlightRecord.summary(['', 'nonsense', 'xx:yy:zz hb 1', '#']);
      expect(text, contains('0 行'));
      expect(text, contains('没有心跳记录'));
    });
  });
}
