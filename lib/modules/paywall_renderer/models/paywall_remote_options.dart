import 'dart:io';

class PaywallRemoteOptions {
  PaywallRemoteOptions(
      {required this.baseUri,
      required this.app,
      required this.environment,
      required Map<String, List<int>> publicKeys,
      required this.cacheDirectory,
      this.allowLoopbackHttp = false})
      : publicKeys = Map.unmodifiable(
            publicKeys.map((k, v) => MapEntry(k, List<int>.unmodifiable(v))));
  final Uri baseUri;
  final String app, environment;
  final Map<String, List<int>> publicKeys;
  final Directory cacheDirectory;
  final bool allowLoopbackHttp;
}
