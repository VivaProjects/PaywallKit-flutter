import 'package:flutter/services.dart';

/// 宿主声明 Flutter 内置页面包，SDK 负责提取、更新和版本回退。
class PaywallQueryFallback {
  PaywallQueryFallback(
      {required this.placement,
      required this.bundledAssetPath,
      required Set<String> fallbackPlacements,
      Set<String>? previousVersionPlacements,
      this.bundle,
      this.updateUrl})
      : fallbackPlacements = Set.unmodifiable(fallbackPlacements),
        previousVersionPlacements =
            Set.unmodifiable(previousVersionPlacements ?? fallbackPlacements);
  final String placement;
  final String bundledAssetPath;
  final Set<String> fallbackPlacements;
  final Set<String> previousVersionPlacements;
  final AssetBundle? bundle;
  final Uri? updateUrl;
}
