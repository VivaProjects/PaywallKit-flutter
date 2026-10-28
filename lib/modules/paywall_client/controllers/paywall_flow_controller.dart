import '../../paywall_renderer/models/paywall_runtime_copy.dart';
import 'dart:async';
import 'dart:convert';
import '../../web_paywall/services/web_paywall_diagnostics.dart';
import 'package:flutter/foundation.dart';
import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/services/web_paywall_resource_cache.dart';
import '../../web_paywall/services/web_paywall_resource_preparation.dart';
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
      this.refreshProductsAfterReuse = false,
      this.presentationOverride,
      this.copy = const PaywallRuntimeCopy(),
      this.timeout = const Duration(seconds: 12)}) {
    presentation = presentationOverride ??
        client.cachedPlacement(placement)?.presentation ??
        WebPaywallPresentation.fullScreen;
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

  /// 允许宿主先展示缓存表面，再校验报价；变化后重建当前页面。
  final bool refreshProductsAfterReuse;

  /// 宿主入口可固定展示方式，配置、离线回退和重试均不能覆盖。
  final WebPaywallPresentation? presentationOverride;
  final PaywallRuntimeCopy copy;
  bool _retainedWeb = false;
  bool presentationFrozen = false;
  late final PaywallFallbackContext fallback;
  final web = ValueNotifier<WebPaywallController?>(null);
  final failure = ValueNotifier<PaywallFailure?>(null);
  final ready = ValueNotifier(false);
  final preparing = ValueNotifier(false);
  PaywallPlacement? selected;
  WebPaywallPresentation presentation = WebPaywallPresentation.fullScreen;
  void Function(PaywallSessionEventType)? onExit;
  Timer? _deadline;
  final _loadClock = Stopwatch();
  int _generation = 0;
  int? _successGeneration;
  Future<void>? _successRecord;
  WebPaywallController? _successWeb;
  WebPaywallResourcePreparation? _resourcePreparation;
  bool _active = true,
      _attached = false,
      _started = false,
      _recovering = false,
      _closing = false;
  bool get isUsable => _active && !_closing && failure.value == null;
  bool get allowsDismiss =>
      web.value?.isProcessing != true &&
      presentation != WebPaywallPresentation.halfSheetLocked &&
      (web.value?.allowsDismiss ?? true);
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
    _loadClock
      ..reset()
      ..start();
    _resourcePreparation?.close();
    final resources = _resourcePreparation = WebPaywallResourcePreparation();
    try {
      final choice = fallback.selected ??
          await (client.usesLaunchSnapshot
              ? fallback.resolve(preparation: resources)
              : fallback
                  .resolve(preparation: resources)
                  .timeout(fallback.remaining));
      WebPaywallDiagnostics.log(
          choice.environment.runtimeEnvironment.name,
          'flow.selection',
          'flow=${identityHashCode(this)} generation=$token placement=$placement durationMs=${_loadClock.elapsedMilliseconds} source=${choice.source}');
      if (client.usesLaunchSnapshot) fallback.retryDeadline();
      if (!_current(token)) return;
      if (selected == null && !presentationFrozen) {
        presentation = presentationOverride ?? choice.presentation;
      }
      await _activate(choice, token);
    } catch (error) {
      if (_current(token))
        await _recover(
            error is PaywallFailure ? error : PaywallFailure.configuration,
            token);
    } finally {
      // 网页已接管则由网页释放；失败或取消前未建立网页的结果在此归还。
      if (!identical(_resourcePreparation, resources) || web.value == null)
        resources.close();
    }
  }

  /// 宿主只能收窄已绑定商品，不能在 prepare 中替换成另一页面或另一环境。
  Future<void> _activate(PaywallPlacement choice, int token) async {
    selected = choice;
    final PaywallSessionInput input;
    try {
      input = await WebPaywallDiagnostics.measure(
          choice.environment.runtimeEnvironment.name,
          'flow.host_prepare',
          () => prepare(choice.document).timeout(fallback.remaining),
          detail:
              'flow=${identityHashCode(this)} generation=$token placement=$placement');
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
    controller.trace('flow.link',
        'flow=${identityHashCode(this)} generation=$token reused=${!identical(controller, fresh)} prepareMs=${_loadClock.elapsedMilliseconds}');
    if (refreshProductsAfterReuse && !identical(controller, fresh)) {
      unawaited(_refreshRetainedProducts(controller, token));
    }
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

  /// 后台结果仅作用于当前展示代次，关闭或切页后丢弃迟到结果。
  Future<void> _refreshRetainedProducts(
      WebPaywallController controller, int token) async {
    final unchanged = await controller.validateRetainedProducts();
    if (!_current(token) || !identical(web.value, controller)) return;
    // H5 仅接收首次 bootstrap；报价变化必须重新握手，不能保留旧披露。
    if (!unchanged) {
      ready.value = false;
      web.value = null;
      controller.destroyPreload();
      await retry();
    }
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
          resourcePreparation: _resourcePreparation,
          requiresRenderReady: true,
          keepSurfaceAlive: client.residentPlacements
                  .contains(input.custom['entryPlacement'] ?? placement) &&
              (presentation == WebPaywallPresentation.fullScreen ||
                  presentation == WebPaywallPresentation.push),
          // 锁定半屏只禁止交互式退场，H5 明确关闭仍遵循宿主授权和交易门禁。
          allowsDismiss: input.allowsDismiss,
          dismiss: closeFromWeb,
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
        remoteDocument: value.remoteDocument,
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
    web.value?.trace('flow.render_observed',
        'flow=${identityHashCode(this)} generation=$token totalMs=${_loadClock.elapsedMilliseconds}');
    _deadline?.cancel();
    ready.value = true;
    preparing.value = false;
    final choice = selected!;
    _emit(PaywallSessionEvent(PaywallSessionEventType.resolved,
        placement: choice));
    _emit(PaywallSessionEvent(PaywallSessionEventType.ready,
        productRefs: web.value!.requestedProductRefs));
    if (jsonEncode(web.value!.document.productRefs) ==
        jsonEncode(choice.document.productRefs)) {
      unawaited(_recordSuccessOnce().catchError((Object _) {}));
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
          _resourcePreparation?.close();
          final resources =
              _resourcePreparation = WebPaywallResourcePreparation();
          final choice =
              await fallback.advance(nextReason, preparation: resources);
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
      if (web.value == null) _resourcePreparation?.close();
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
    _resourcePreparation?.close();
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

  /// H5 明确关闭不受半屏手势锁限制，但隐藏、交易中和未授权页面不能关闭。
  void closeFromWeb() {
    final value = web.value;
    if (!_attached ||
        value == null ||
        !value.allowsDismiss ||
        value.isProcessing) {
      return;
    }
    close(force: true);
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
    _resourcePreparation?.close();
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

  /// 同一代次的同一网页共享成功记录，自动回退后的新网页独立提交。
  Future<void> _recordSuccessOnce() {
    final currentWeb = web.value!;
    if (_successGeneration == _generation &&
        identical(_successWeb, currentWeb) &&
        _successRecord != null) {
      return _successRecord!;
    }
    final token = _generation;
    final choice = selected!;
    _successGeneration = token;
    _successWeb = currentWeb;
    return _successRecord = Future<void>.sync(() => client.recordSuccess(
        choice, () => _current(token) && identical(web.value, currentWeb)));
  }

  /// 常驻预热成功后保留表面，归档完成前仍允许验证当前准备身份。
  Future<bool> parkInCache(bool Function() isCurrent) async {
    final currentWeb = web.value;
    final token = _generation;
    if (!ready.value || !isUsable || web.value == null || selected == null)
      return false;
    try {
      await _recordSuccessOnce();
    } catch (_) {/* 历史不可写不阻断当前已就绪缓存。 */}
    if (!_current(token) ||
        !isCurrent() ||
        !ready.value ||
        !identical(web.value, currentWeb)) return false;
    _retainedWeb = client.retainPage(placement, cacheIdentity, currentWeb!);
    if (_retainedWeb) cancel();
    return _retainedWeb;
  }

  /// 未挂载的预渲染和路由释放共用同一清理入口。
  void cancel() {
    _resourcePreparation?.close();
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
