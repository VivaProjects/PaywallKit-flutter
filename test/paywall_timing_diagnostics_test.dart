import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/modules/web_paywall/services/paywall_logging.dart';
import 'package:native_paywall/modules/web_paywall/services/web_paywall_diagnostics.dart';

void main() {
  late DebugPrintCallback original;
  late PaywallLoggingMode previous;
  final lines = <String>[];
  setUp(() {
    original = debugPrint;
    previous = PaywallLogging.mode;
    lines.clear();
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    PaywallLogging.mode = PaywallLoggingMode.enabled;
  });
  tearDown(() {
    debugPrint = original;
    PaywallLogging.mode = previous;
  });

  test('paired spans distinguish concurrent operations and preserve results',
      () async {
    final results = await Future.wait([
      WebPaywallDiagnostics.measure('test', 'stage', () async => 1,
          detail: 'document=a'),
      WebPaywallDiagnostics.measure('test', 'stage', () async => 2,
          detail: 'document=b'),
    ]);
    expect(results, [1, 2]);
    final starts = lines.where((line) => line.contains('stage.begin')).toList();
    final ends = lines.where((line) => line.contains('stage.end')).toList();
    expect(starts, hasLength(2));
    expect(ends, hasLength(2));
    final ids = starts
        .map((line) => RegExp(r'span=(\d+)').firstMatch(line)!.group(1))
        .toSet();
    expect(ids, hasLength(2));
    for (final id in ids) {
      expect(ends.where((line) => line.contains('span=$id ')), hasLength(1));
    }
    expect(
        ends.every((line) =>
            line.contains('durationMs=') &&
            line.contains('status=ok') &&
            line.contains('tMs=')),
        isTrue);
  });

  test('failed operation keeps original error without logging its payload',
      () async {
    final error = StateError('private-price-and-user-payload');
    await expectLater(
        WebPaywallDiagnostics.measure('test', 'stage', () async => throw error),
        throwsA(same(error)));
    expect(lines.last, contains('status=error'));
    expect(lines.join(), isNot(contains('private-price-and-user-payload')));
  });

  test('disabled printing still records readable spans in both environments',
      () async {
    PaywallLogging.mode = PaywallLoggingMode.disabled;
    var calls = 0;
    expect(
        await WebPaywallDiagnostics.measure(
            'test', 'muted-test-stage', () async => ++calls),
        1);
    expect(calls, 1);
    expect(lines, isEmpty);
    PaywallLogging.mode = PaywallLoggingMode.automatic;
    await WebPaywallDiagnostics.measure(
        'production', 'muted-production-stage', () async => 1);
    expect(lines, isEmpty);
    final recorded = await PaywallLogging.read();
    expect(recorded, contains('muted-test-stage.begin'));
    expect(recorded, contains('muted-test-stage.end'));
    expect(recorded, contains('muted-production-stage.end'));
    expect(recorded, contains('run='));
    expect(recorded, contains('wallMs='));
  });
}
