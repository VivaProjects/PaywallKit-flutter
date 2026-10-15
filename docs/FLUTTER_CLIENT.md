# Flutter 高层 H5 SDK

高层入口负责配置、归因、页面包、回退、预渲染、展示和会话生命周期。宿主仍负责真实购买、恢复、权益验证、业务资格和法律页面。H5 只展示 `content.json` 与商店报价，并发送桥接动作。

## Git 依赖

```yaml
dependencies:
  native_paywall:
    git:
      url: git@github.com:VivaProjects/PaywallKit-flutter.git
      ref: 0.2.0
```

## 查询与归因

```dart
final client = PaywallClient.query(
  query: PaywallQueryConfiguration(
    endpoint: Uri.parse('https://api.example.com/paywall/query'),
    cacheNamespace: 'my-app',
    runtimeEnvironment: WebPaywallRuntimeEnvironment.production,
    allowedOrigins: {'https://cdn.example.com'},
    placements: {'server_settings': 'settings', 'server_banner': 'banner'},
    fallback: PaywallQueryFallback(
      placement: 'settings',
      bundledAssetPath: 'assets/paywall/settings',
      fallbackPlacements: {'banner', 'unlock'},
    ),
  ),
  catalog: () => registeredCatalog,
  retainedPlacements: {'settings', 'banner'},
);

// 第三方归因 SDK 的成功或失败回调仅转交此入口。
await client.reportAttribution(channel: confirmedChannel, failed: false);
await client.preloadConfiguration();
```

首次未知归因最多等待五秒；成功自然量保存为 `organic`，失败与超时的默认值不持久化。已确认渠道按宿主 namespace 和运行环境隔离保存。渠道改变会使旧配置请求失效并自动刷新。前台恢复最多每小时查询一次；商店国家改变立即刷新。

默认环境由平台插件采集语言、机型、用户可见应用版本。iOS 15+ 自动读取 StoreKit 账户国家并监听变化；低版本无法取得时为空。Android 不把设备地区当商店国家，可通过 `environment` 回调调用 `PaywallEnvironmentProvider.capture(storefrontCountry: ...)` 对接宿主 Billing 服务，并传入 `storefrontChanges` 流。国家只接受空值或三位字母，统一大写。`runtimeEnvironment` 默认 `test`，生产必须显式配置；环境回调必须返回同一运行环境。

POST 使用 `channelKey` 和 `conditions.version/device_type/language/country`。接口仅返回点位与 `h5Url`，商品绑定和版本从对应 `package.json` 读取；完整资源校验后才进入配置。坏页面只影响对应点位。`allowedOrigins: null` 显式关闭页面白名单，空集合拒绝所有页面。开发 HTTP 仅 Debug/Test 且来源与 `developmentHTTPOrigin` 完全一致时开放。

标准 GET 配置可使用 `PaywallClient(configuration: PaywallConfigurationSource(...))`，通过 `PaywallRequestParameters(environment: ..., additional: ...).request(endpoint)` 生成稳定排序的参数。附加字段不能覆盖标准环境参数。自定义 `fetch` 对接宿主网络层时，宿主必须保留超时、响应大小、来源与重定向限制。

## 宿主与展示

在宿主 GetX 路由 Binding 中使用 `PaywallPresentationBinding` 注册协调器，或由已有 Binding 注册 `PaywallPresentationController`。不要在 Widget 中注册依赖。

```dart
final coordinator = Get.find<PaywallPresentationController>();

// 宿主页面用此容器承载隐藏预渲染；showLoading 可用于被动入口静默准备。
PaywallHost(
  controller: coordinator,
  child: existingPage,
  canPresent: canShowPaywall,
  preparationIdentity: currentEligibilityIdentity,
);

final presenter = PaywallPresenter(controller: coordinator);
await presenter.present(
  placement: 'banner',
  waitsForReady: true,
  canPresent: () => canShowPaywall,
  create: (placement) => PaywallFlowController(
    client: client,
    placement: placement,
    cacheIdentity: currentPriceAndEligibilityIdentity,
    prepare: (document) async => PaywallSessionInput(
      document: document,
      purchaseBridge: purchaseBridge,
      environment: await PaywallEnvironmentProvider.capture(
        runtimeEnvironment: WebPaywallRuntimeEnvironment.production,
      ),
      custom: {'flow': 'upgrade'},
    ),
    openLegal: openLegal,
    onEvent: handlePaywallEvent,
  ),
);
```

四种服务端模式自动选择全屏、可关闭半屏、锁定半屏或 Push 路由。半屏使用带会话标识的 `contentHeight` 回执，200ms 合并上报后冻结高度，宽度改变才重新计算；拖动只移动已渲染表面，不重排 H5。锁定模式禁止遮罩、拖动、返回和网页关闭。

`PaywallFlowController` 负责配置到首屏的总期限、商品与渲染失败分类、重试和资源释放。`prepare` 可在宿主资格检查后收窄当前清单商品，不能替换页面、版本或运行环境。加载/错误原生文案可传 `PaywallRuntimeCopy`，不会注入 H5。

`ready / resolved / closed / retrying / purchaseFinished / restoreFinished / actionFailed / failed` 分开上报。成功交易结束交互；取消、pending、恢复无权益保留当前页。`nextPlacement` 只在主动关闭后接续，成功交易不触发挽留；SDK 等待真实路由 `completed` 后才开始下一点位，循环接续被阻断。可设置 `followNextPlacement: false` 交由宿主接续。

普通 `resolve` 缺失点位返回 null，明确禁用抛出 `PaywallFailure.disabled`。禁用不可当作资源故障再次打开。`cachedPlacement` 同步读取当前快照；`invalidate` 影响后续解析，不改写已经显示的会话。

## 离线包、更新与历史

把完整发布包作为 Flutter assets 声明，包括 `package.json`、`offline.html`、`offline.js`、`content.json`、`page.json` 和清单内所有资源；资源子目录也须在宿主 pubspec 中登记。SDK 按清单提取到排除备份的私有目录，逐文件验证路径、大小与 SHA-256 后使用，不依赖相邻仓库。

- 支持 v1 单环境包和 v2 shared 包，shared 必须含完整 Test/Production 绑定。缺失环境不得跨环境回退。
- 本地专属点位直接使用更新包或内置包，打开不等待网络。查询响应中的本地点位完整包由 SDK 自动接收更新；也可配置 `updateUrl`，使用 `refreshIfNeeded()` 每小时检查更新描述。
- 更新包完整校验后才原子激活，保留当前和前版；版本不倒退。明确的 `disabledPlacements` 策略独立持久化，不能因包下载失败或旧版本响应而重新打开。
- 只有资源或桥接故障会拒绝更新包版本；商品离线、取消或资格失败不污染包健康状态。
- `previousVersionPlacements` 默认等于授权的 `fallbackPlacements`，可显式收窄。仅首屏成功且完整包可归档时记录最近两个版本，并按 namespace、完整请求、环境、实际入口和 documentId 隔离。
- 一次展示单向尝试：当前版本 → 同文档最近较低成功版本 → 本地更新包 → 内置包。每个候选有独立总期限。历史只尝试一次，损坏或不兼容直接跳过；明确禁用、取消和资格失效优先结束。
- 普通资源 LRU 不删除成功版本和本地包。成功索引最多两个版本；无索引包在仓库下次冷启动打开时回收，活跃租约保护正在读取的目录。

高级宿主可直接构造 `PaywallPackageArchive`、`PaywallLocalPackageStore`、`PaywallHistoryStore`，通过 `client.useLocalPackages` 接入自定义内置资源加载和更新流程。

## 预渲染与常驻缓存

`PaywallPreload.start(flow, cacheIdentity: ...)` 提前准备一次会话，使用 `PaywallPreparationView(preload: ...)` 为其提供真实布局空间。准备页透明且不可触摸，不允许购买、恢复或法律跳转。12 秒内没有首屏回执会取消；就绪后停止计时。

正式展示把该句柄传给 `presenter.present(preload: ..., cacheIdentity: ...)`。仅同一 Client、同一点位及同一资格身份可以消费一次；失效句柄不会退回可见加载。宿主资格或 `PaywallHost.preparationIdentity` 改变，会取消尚未提交的准备，不误取消已经提交的弹窗。

`retainedPlacements` 为指定入口保留已就绪、无进行中交易的网页。后续展示同时检查完整会话身份与宿主 `cacheIdentity`，并重绑当前购买桥和业务回调；价格、资格或权益变化必须改变该身份。`invalidatePage` 显式释放某入口缓存。

`PaywallCachedPreload.start(flow)` 可在后台预热常驻入口，搭配 `PaywallPreparationView(preload: warmer.preload)`。首屏成功后归档并把表面交给 Client，正式展示重建业务回调；取消预热会移除对应常驻缓存。

## 商店桥与数据边界

宿主实现 `PaywallPurchaseBridge`。iOS 15+ 可选用 `PaywallStoreKitProductMapper.products(productRefs, includesDailyPrice: ...)` 获取默认 StoreKit 价格、订阅周期、优惠资格和披露；它不购买、不验单。Android 保留宿主 Google Play Billing 实现，不引入第二套交易 SDK。

商品名称、按钮、卖点和法律标签均由 H5 维护。bootstrap 仅注入价格及披露、宿主确认资格、标准适配环境、实际点位、受限 custom 与必要桥元数据。custom 冻结为最多 16 KiB 的 JSON，不能覆盖标准环境、商店报价或内容。预览演示价格不进入原生正式会话。

## 验证边界

能力对应与回归证据见 [iOS 能力对照](IOS_PARITY.md)。本仓库执行 Dart 静态分析、单元/Widget 测试、协议与独立发布检查；真实 WebView 渲染、iOS/Android 原生构建和商店交易仍需宿主设备验证。测试替身不能证明真实购买成功。
