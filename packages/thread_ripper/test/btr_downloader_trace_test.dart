// The Dart downloader against upstream's own: every scripted network in
// test/fixtures/btr_scenarios.json must produce the trace that upstream's
// JavaScript produced on it (test/fixtures/btr_traces.json, written by
// tool/generate_btr_traces.cjs).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'btr_harness.dart';

void main() {
  // BTR_FIXTURES: another directory with both files (for trying scenarios out).
  final dir = Platform.environment['BTR_FIXTURES'] ?? 'test/fixtures';
  final input = jsonDecode(
    File('$dir/btr_scenarios.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final traces =
      jsonDecode(File('$dir/btr_traces.json').readAsStringSync()) as List;
  final defaults = Map<String, Object?>.from(input['defaults']! as Map);
  final scenarios = (input['scenarios']! as List).cast<Map>();

  test('every scenario has an upstream trace', () {
    expect(
      traces.map((trace) => (trace as Map)['name']).toList(),
      scenarios.map((scenario) => scenario['name']).toList(),
    );
  });

  for (final raw in scenarios) {
    final scenario = mergeScenario(defaults, Map<String, Object?>.from(raw));
    final name = scenario['name']! as String;
    test('downloader matches upstream: $name', () {
      final expected = canonicalEvents(
        (traces.firstWhere((trace) => (trace as Map)['name'] == name)
                as Map)['events']
            as List,
      );
      final actual = canonicalEvents(runScenario(scenario));
      final length = expected.length < actual.length
          ? expected.length
          : actual.length;
      var at = 0;
      while (at < length && expected[at] == actual[at]) {
        at++;
      }
      if (at == expected.length && at == actual.length) return;
      String around(List<String> list) => list
          .sublist(
            at > 2 ? at - 2 : 0,
            at + 4 > list.length ? list.length : at + 4,
          )
          .join('\n    ');
      fail(
        'first difference at event $at '
        '(upstream ${expected.length} events, port ${actual.length})\n'
        '  upstream:\n    ${around(expected)}\n'
        '  port:\n    ${around(actual)}',
      );
    });
  }
}
