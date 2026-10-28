import 'dart:convert';

import 'web_paywall_document.dart';
import 'web_paywall_environment.dart';

/// 将环境和页面绑定序列化为稳定身份，防止跨环境复用预加载页面。
String webPaywallSessionIdentity({
  required WebPaywallDocument document,
  required String storefrontGroup,
  required WebPaywallEnvironment environment,
  required String customIdentity,
}) =>
    jsonEncode([
      document.documentId,
      document.revision,
      document.pageUri.toString(),
      document.localDirectory?.path,
      document.catalogKey,
      document.productRefs,
      document.initialProductRef,
      storefrontGroup,
      environment.toPayload(),
      // 等待策略变化时不能复用此前提前就绪的页面。
      environment.waitsForProducts,
      customIdentity,
    ]);
