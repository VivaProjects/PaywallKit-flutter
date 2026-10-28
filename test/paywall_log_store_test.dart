import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/modules/web_paywall/services/paywall_log_store.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paywall-log-store-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('bounded rotation survives restart; export and clear use only SDK files',
      () async {
    final store = PaywallLogStore(
        directory: () async => root, fileBytes: 128, bufferBytes: 8192);
    await File('${root.path}/host.txt').writeAsString('untouched');
    for (var index = 0; index < 40; index++) {
      store.append('event-$index payload');
    }
    final text = await store.read();
    expect(text, contains('event-39'));
    expect(text, isNot(contains('event-0 ')));
    final files =
        await root.list().where((file) => file.path.endsWith('.log')).toList();
    expect(files, hasLength(3));
    for (final file in files) {
      expect(await File(file.path).length(), lessThanOrEqualTo(128));
    }
    final restarted =
        PaywallLogStore(directory: () async => root, fileBytes: 128);
    expect(await restarted.read(), text);
    final exported = await restarted.export();
    expect(await exported.readAsString(), text);
    expect((await restarted.export()).path, exported.path);
    await restarted.clear();
    expect(await restarted.read(), isEmpty);
    expect(await File('${root.path}/host.txt').readAsString(), 'untouched');
    restarted.append('after-clear');
    expect(await restarted.read(), contains('after-clear'));
  });

  test(
      'storage failure retains bounded memory and recovers without losing newest events',
      () async {
    final unavailable = File('${root.path}/blocked');
    await unavailable.writeAsString('not-a-directory');
    var target = Directory(unavailable.path);
    final store =
        PaywallLogStore(directory: () async => target, bufferBytes: 256);
    for (var index = 0; index < 100; index++) {
      store.append('event-$index');
    }
    final memory = await store.read();
    expect(memory, contains('logs.storage_unavailable'));
    expect(memory, contains('logs.dropped'));
    expect(memory, contains('event-99'));
    expect(memory.length, lessThan(512));
    target = Directory('${root.path}/recovered');
    final recovered = await store.read();
    expect(recovered, contains('event-99'));
    expect(recovered, isNot(contains('logs.storage_unavailable')));
    expect(
        await PaywallLogStore(directory: () async => target).read(), recovered);
  });

  test('events arriving during a batch are persisted without another append',
      () async {
    final entered = Completer<void>(), resume = Completer<void>();
    var calls = 0;
    final store = PaywallLogStore(directory: () async {
      if (++calls == 1) {
        entered.complete();
        await resume.future;
      }
      return root;
    });
    store.append('first');
    await entered.future;
    store.append('during-write');
    resume.complete();
    for (var i = 0; i < 100; i++) {
      final file = File('${root.path}/paywall-0.log');
      if (await file.exists() &&
          (await file.readAsString()).contains('during-write')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await File('${root.path}/paywall-0.log').readAsString(),
        contains('during-write'));
    await store.read();
  });
}
