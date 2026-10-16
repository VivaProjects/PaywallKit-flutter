import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SDK dependencies and production imports remain framework independent',
      () {
    const allowed = {'flutter', 'crypto', 'cryptography', 'webview_flutter'};
    final manifest = File('pubspec.yaml').readAsStringSync();
    final dependencies =
        manifest.split('\ndependencies:\n')[1].split(RegExp(r'\n\S'))[0];
    final declared = RegExp(r'^  ([a-z][a-z0-9_]*):', multiLine: true)
        .allMatches(dependencies)
        .map((match) => match[1]!)
        .toSet();
    expect(declared.difference(allowed), isEmpty,
        reason:
            'Runtime dependencies require an SDK architecture review. See AGENTS.md.');
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final packages = RegExp(r'''(?:import|export)\s+['"]package:([^/]+)/''')
          .allMatches(file.readAsStringSync())
          .map((match) => match[1]);
      expect(
          packages.toSet().difference({...allowed, 'native_paywall'}), isEmpty,
          reason: '${file.path} must not import host frameworks.');
    }
    // 检查解析结果，防止通过另一个依赖间接带入应用框架。
    const prohibited = {
      'get',
      'provider',
      'riverpod',
      'flutter_riverpod',
      'hooks_riverpod',
      'bloc',
      'flutter_bloc',
      'get_it',
      'injectable',
      'go_router',
      'auto_route',
      'stacked',
      'flutter_hooks',
    };
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync());
    final resolved = (config['packages'] as List)
        .map((package) => package['name'] as String)
        .toSet();
    expect(resolved.intersection(prohibited), isEmpty,
        reason:
            'SDK cannot transitively require host state, routing or DI frameworks.');
  });
}
