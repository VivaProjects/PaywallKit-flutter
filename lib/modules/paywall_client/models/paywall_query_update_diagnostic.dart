/// 后台更新终态；仅日志启用时交给宿主展示，不代表线上发布。
class PaywallQueryUpdateDiagnostic {
  const PaywallQueryUpdateDiagnostic.completed({
    required this.updatedPlacements,
    required this.failures,
  }) : failed = false;
  const PaywallQueryUpdateDiagnostic.failed()
      : failed = true,
        updatedPlacements = 0,
        failures = 0;
  final bool failed;
  final int updatedPlacements;
  final int failures;
}
