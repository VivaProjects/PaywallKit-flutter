import '../../paywall_renderer/models/paywall_runtime_copy.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/services/web_paywall_resource_cache.dart';
import '../models/paywall_failure.dart';
import '../models/paywall_placement.dart';
import '../models/paywall_session_input.dart';
import '../models/paywall_session_event.dart';
import '../services/paywall_client.dart';
import '../services/paywall_fallback_context.dart';

/// 页面级状态机统一准备、回退、重试和交易生命周期，由展示路由显式持有。
class PaywallFlowController {
  PaywallFlowController(
      {required this.client,
      required this.placement,
      required this.prepare,
      required this.openLegal,
      this.onEvent,
      this.resourceCache,
      this.cacheIdentity = 0,
      this.presentationOverride,
      this.copy = const PaywallRuntimeCopy(),
      this.timeout = const Duration(seconds: 12)}) {
    presentation = presentationOverride ?? WebPaywallPresentation.fullScreen;
    fallback = PaywallFallbackContext(
        client: client, placement: placement, timeout: timeout);
  }
  final PaywallClient client;
  final String placement;
  final Future<PaywallSessionInput> Function(WebPaywallDocument) prepare;
  void Function(String) openLegal;
  void Function(PaywallSessionEvent)? onEvent;
  final WebPaywallResourceCache? resourceCache;
  final Duration timeout;
  final Object cacheIdentity;

  /// 宿主入口可固定展示方式，配置、离线回退和重试均不能覆盖。
  final WebPaywallPresentation? presentationOverride;
  final PaywallRuntimeCopy copy;
  bool _retainedWeb = false;
  late final PaywallFallbackContext fallback;
  final web = ValueNotifier<WebPaywallController?>(null);
  final failure = ValueNotifier<PaywallFailure?>(null);
  final ready = ValueNotifier(false);
  final preparing = ValueNotifier(false);
  PaywallPlacement? selected;
  WebPaywallPresentation presentation = WebPaywallPresentation.fullScreen;
  void Function(PaywallSessionEventType)? onExit;
  Timer? _deadline;
  int _generation = 0;
  bool _active = true,
      _attached = false,
      _started = false,
      _recovering = false,
      _closing = false;
  bool get isUsable => _active && !_closing && failure.value == null;
  bool get allowsDismiss =>
      web.value?.isProcessing != true &&
      (web.value?.allowsDismiss ??
          presentation != WebPaywallPresentation.halfSheetLocked);
  String? get nextPlacement => selected?.sessionPolicy?.nextPlacement;

  /// 普通进入开始准备，已预渲染页面直接接管，不重复查询商品。
  void start() {
    if (!_active || _closing) return;
    attach();
    if (!_started) unawaited(load());
  }

  /// 预加载只冻结网页和输入，正式接管时替换为当前宿主的事件与法律回调。
  void bindPresentationCallbacks(PaywallFlowController fresh) {
    onEvent = fresh.onEvent;
    openLegal = fresh.openLegal;
    web.value?.openLegal = fresh.openLegal;
  }

  /// 只有正式展示后才开放页面动作，隐藏准备页不能购买或关闭。
  void attach() {
    _attached = true;
    web.value?.attachPresentation();
  }

  /// 隐藏视图同时暂停当前网页与后续回退网页的动作权限。
  void detach() {
    _attached = false;
    web.value?.pausePresentation();
  }

  /// 配置和资格准备共用本次截止时间，晚到结果不重建会话。
  Future<void> load() async {
    if (!_active || _closing) return;
    _started = true;
    preparing.value = true;
    failure.value = null;
    final token = ++_generation;
    try {
      final choice = fallback.selected ??
          await fallback.resolve().timeout(fallback.remaining);
      if (!_current(token)) return;
      if (selected == null) {
        presentation = presentationOverride ?? choice.presentation;
      }
      await _activate(choice, token);
    } catch (error) {
      if (_current(token))
        await _recover(
            error is PaywallFailure ? error : PaywallFailure.configuration,
            token);
    }
  }

  /// 宿主只能收窄已绑定商品，不能在 prepare 中替换成另一页面或另一环境。
  Future<void> _activate(PaywallPlacement choice, int token) async {
    selected = choice;
    final PaywallSessionInput input;
    try {
      input = await prepare(choice.document).timeout(fallback.remaining);
    } catch (error) {
      throw error is PaywallFailure ? error : PaywallFailure.eligibility;
    }
    if (!_current(token)) return;
    _validateInput(input, choice);
    _emit(PaywallSessionEvent(PaywallSessionEventType.resolved,
        placement: choice));
    final fresh = _createWeb(input, choice, token);
    final controller =
        client.takeRetainedPage(placement, cacheIdentity, fresh) ?? fresh;
    web.value = controller;
    _deadline?.cancel();
    _deadline = Timer(
        fallback.remaining.isNegative ? Duration.zero : fallback.remaining, () {
      if (_current(token) && !ready.value)
        unawaited(_recover(
            web.value?.awaitingProducts == true
                ? PaywallFailure.productsUnavailable
                : PaywallFailure.renderTimeout,
            token));
    });
    controller.preload();
    if (controller.ready.value) _rendered(token);
    if (_attached) controller.attachPresentation();
  }

  /// 交易和网页事件仅投递给当前 generation，防止回退后的旧回调干扰新页面。
  WebPaywallController _createWeb(
          PaywallSessionInput input, PaywallPlacement choice, int token) =>
      WebPaywallController(
          document: input.document,
          storefrontGroup: placement,
          environment: input.environment.forPlacement(placement),
          bridge: input.purchaseBridge,
          custom: input.custom,
          sessionPolicy: choice.sessionPolicy,
          resourceCache: resourceCache,
          requiresRenderReady: true,
          allowsDismiss: input.allowsDismiss &&
              presentation != WebPaywallPresentation.halfSheetLocked,
          dismiss: close,
          openLegal: openLegal,
          onRenderReady: () => _rendered(token),
          onResourceSource: (source) => _resourceSource(token, source),
          onFailure: (reason) {
            if (_current(token)) unawaited(_recover(reason, token));
          },
          onPurchaseResult: (ref, result) => _transaction(
              token, PaywallSessionEventType.purchaseFinished, result, ref),
          onRestoreResult: (result) => _transaction(
              token, PaywallSessionEventType.restoreFinished, result, null),
          onActionFailure: (action) {
            if (_current(token))
              _emit(PaywallSessionEvent(PaywallSessionEventType.actionFailed,
                  action: action));
          });

  /// 拒绝跨文档、跨版本、跨运行环境准备，商品可由宿主资格收窄。
  void _validateInput(PaywallSessionInput input, PaywallPlacement choice) {
    final a = input.document, b = choice.document;
    if (a.documentId != b.documentId ||
        a.revision != b.revision ||
        a.pageUri != b.pageUri ||
        a.localDirectory?.path != b.localDirectory?.path ||
        a.catalogKey != b.catalogKey ||
        a.productRefs.any((ref) => !b.productRefs.contains(ref)) ||
        input.environment.runtimeEnvironment !=
            choice.environment.runtimeEnvironment)
      throw PaywallFailure.eligibility;
  }

  /// 首次来源明确后更新曝光归因，历史与内置来源不被普通磁盘命中覆盖。
  void _resourceSource(int token, String source) {
    final value = selected;
    if (!_current(token) || value == null || value.source != 'remote_or_cache')
      return;
    selected = PaywallPlacement(
        name: value.name,
        document: value.document,
        environment: value.environment,
        presentation: value.presentation,
        sessionPolicy: value.sessionPolicy,
        requestIdentity: value.requestIdentity,
        configurationSnapshot: value.configurationSnapshot,
        clientIdentity: value.clientIdentity,
        source: source,
        fallbackReason: value.fallbackReason);
  }

  /// 首屏只上报一次，完整包归档失败不影响已经成功显示的页面。
  void _rendered(int token) {
    if (!_current(token) || ready.value) return;
    _deadline?.cancel();
    ready.value = true;
    preparing.value = false;
    final choice = selected!;
    _emit(PaywallSessionEvent(PaywallSessionEventType.resolved,
        placement: choice));
    _emit(PaywallSessionEvent(PaywallSessionEventType.ready,
        productRefs: web.value!.document.productRefs));
    if (jsonEncode(web.value!.document.productRefs) ==
        jsonEncode(choice.document.productRefs)) {
      unawaited(client
          .recordSuccess(choice, () => _current(token))
          .catchError((Object _) {}));
    }
  }

  /// 失败单向前进，坏更新包只因资源/桥错误被隔离，取消与禁用立即结束。
  Future<void> _recover(PaywallFailure reason, int token) async {
    if (!_current(token) || _recovering) return;
    _recovering = true;
    _deadline?.cancel();
    ready.value = false;
    web.value?.destroyPreload();
    web.value = null;
    try {
      if (reason.invalidatesPackage && selected?.source == 'update')
        await fallback.store?.reject(selected!.document);
      var nextReason = reason;
      for (var attempt = 0; attempt < 4 && _current(token); attempt++) {
        if (nextReason == PaywallFailure.disabled ||
            nextReason == PaywallFailure.cancelled ||
            fallback.usesHistory && nextReason == PaywallFailure.eligibility) {
          close(force: true);
          return;
        }
        try {
          final choice = await fallback.advance(nextReason);
          if (!_current(token)) return;
          if (choice == null) {
            _fail(nextReason);
            return;
          }
          await _activate(choice, token);
          return;
        } catch (error) {
          nextReason =
              error is PaywallFailure ? error : PaywallFailure.resource;
        }
      }
      if (_current(token)) _fail(nextReason);
    } finally {
      _recovering = false;
    }
  }

  /// 重试保留当前回退分支，不重试已失败的远端页面。
  Future<void> retry() async {
    if (!_active || _closing) return;
    _emit(const PaywallSessionEvent(PaywallSessionEventType.retrying));
    fallback.retryDeadline();
    await load();
  }

  /// 错误页保留关闭入口，不再接受旧网页消息。
  void _fail(PaywallFailure reason) {
    failure.value = reason;
    preparing.value = false;
    _emit(PaywallSessionEvent(PaywallSessionEventType.failed, failure: reason));
  }

  /// 成功交易结束交互，与主动关闭分开，避免错误触发后续挽留点位。
  void _transaction(int token, PaywallSessionEventType type,
      PaywallPurchaseResult result, String? ref) {
    if (!_current(token) || !_attached) return;
    _emit(PaywallSessionEvent(type, productRef: ref, result: result));
    if (result == PaywallPurchaseResult.succeeded) _exit(type);
  }

  /// 主动关闭仅上报一次，错误页允许退出以避免锁死用户流程。
  void close({bool force = false}) {
    if (!_active ||
        _closing ||
        (!force && !allowsDismiss && failure.value == null)) return;
    _emit(const PaywallSessionEvent(PaywallSessionEventType.closed));
    _exit(PaywallSessionEventType.closed);
  }

  /// 标记退出后立即阻断动作，路由退场完成后才释放展示所有权。
  void _exit(PaywallSessionEventType type) {
    _closing = true;
    _generation++;
    _deadline?.cancel();
    final value = web.value;
    if (value != null) {
      _retainedWeb = type == PaywallSessionEventType.closed &&
          client.retainPage(placement, cacheIdentity, value);
      if (!_retainedWeb) value.destroyPreload();
    }
    onExit?.call(type);
  }

  /// 外部观察回调异常不能改变真实交易或状态机结果。
  void _emit(PaywallSessionEvent event) {
    try {
      onEvent?.call(event);
    } catch (_) {/* 隔离宿主观察者错误。 */}
  }

  /// 每次异步恢复必须验证当前会话仍在使用同一代状态。
  bool _current(int token) => _active && !_closing && token == _generation;

  /// 常驻预热成功后保留表面，归档完成前仍允许验证当前准备身份。
  Future<bool> parkInCache(bool Function() isCurrent) async {
    if (!ready.value || !isUsable || web.value == null || selected == null)
      return false;
    try {
      await client.recordSuccess(selected!, () => _active && isCurrent());
    } catch (_) {/* 历史不可写不阻断当前已就绪缓存。 */}
    if (!_active || !isCurrent()) return false;
    _retainedWeb = client.retainPage(placement, cacheIdentity, web.value!);
    if (_retainedWeb) cancel();
    return _retainedWeb;
  }

  /// 未挂载的预渲染和路由释放共用同一清理入口。
  void cancel() {
    _active = false;
    _generation++;
    _deadline?.cancel();
    if (!_retainedWeb) web.value?.destroyPreload();
    web.value = null;
  }

  bool _disposed = false;

  /// 路由卸载后释放监听状态，已交给 Client 的缓存网页继续存活。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    web.dispose();
    failure.dispose();
    ready.dispose();
    preparing.dispose();
  }
}
