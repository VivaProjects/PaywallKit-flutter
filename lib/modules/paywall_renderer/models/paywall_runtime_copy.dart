/// 宿主提供本地化文案，法律入口不受在线编辑影响。
class PaywallRuntimeCopy {
  const PaywallRuntimeCopy(
      {this.restore = 'Restore purchases',
      this.privacy = 'Privacy',
      this.terms = 'Terms',
      this.retry = 'Retry',
      this.loading = 'Loading products…',
      this.unavailable = 'Products are unavailable. Please try again.',
      this.failed = 'The request could not be completed. Please try again.',
      this.pending = 'Awaiting purchase approval.',
      this.succeeded = 'Purchase verified.',
      this.noEntitlement = 'No active purchases were found.',
      this.recommended = 'Recommended'});
  final String restore, privacy, terms, retry, loading, unavailable;
  final String failed, pending, succeeded, noEntitlement, recommended;
}
