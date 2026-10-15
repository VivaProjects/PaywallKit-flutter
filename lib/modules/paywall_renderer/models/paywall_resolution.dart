import 'paywall_snapshot.dart';

enum PaywallResolutionSource { remote, lastKnownGood, bundled, native }

class PaywallResolution {
  PaywallResolution(this.snapshot, this.source, List<String> failures)
      : failures = List.unmodifiable(failures);
  final PaywallSnapshot? snapshot;
  final PaywallResolutionSource source;
  final List<String> failures;
}
