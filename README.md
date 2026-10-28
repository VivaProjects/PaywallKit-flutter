# native_paywall Flutter SDK

独立 Flutter SDK 仓库。根目录即 Flutter package，包含 Dart/Flutter 实现、Android/iOS 原生插件、资源、测试和协议快照；不依赖 iOS PaywallKit 或 H5 管理项目。

## 接入

本地开发指向本目录：

```yaml
dependencies:
  native_paywall:
    path: ../flutter
```

通过独立 Git 仓库接入：

```yaml
dependencies:
  native_paywall:
    git:
      url: git@github.com:VivaProjects/PaywallKit-flutter.git
      ref: 1.6.0
```

iOS 插件当前使用 CocoaPods。宿主若默认开启 Swift Package Manager，请在宿主 `pubspec.yaml` 的 `flutter.config` 中设置 `enable-swift-package-manager: false`。

包已经位于仓库根目录，无需 Git `path` 字段。使用版本标签固定依赖。当前配置保留 `publish_to: none`，支持 Git 发布与接入，不代表已具备 pub.dev 公共发布条件。

## 检查与发布

```sh
python3 tools/check_package.py
python3 tools/version.py check
flutter pub get
flutter analyze
flutter test
dart run tool/check_contract.dart
```

版本唯一来源为 `pubspec.yaml`；`tools/version.py` 升版时同步本仓库 `ios/native_paywall.podspec`，不涉及另一个 iOS SDK 仓库。

- [发布说明](docs/RELEASING.md)
- [宿主接入](docs/INTEGRATION.md)
- [H5 桥接](docs/WEB_PAYWALL.md)
- [协议契约](docs/PROTOCOL.md)

协议和回退资源均为本仓库快照。改桥接时检查其他实现兼容性，但不强制各仓库版本号相同。

Flutter 高层配置查询、点位解析与会话接入见 [Flutter Client](docs/FLUTTER_CLIENT.md)。

完整高层能力和回归证据见 [iOS 能力对照](docs/IOS_PARITY.md)。

SDK 不依赖宿主状态管理、路由或依赖注入框架，可在普通 MaterialApp 中使用。1.0.0 的无 GetX API 与 0.2.0 不兼容，升级说明见 [框架独立性与迁移](docs/FRAMEWORK_INDEPENDENCE.md)。

1.1.0 新增启动快照与单次查询、延迟商品加载、日志开关和展示通知；行为迁移与新增接口见 [Flutter Client](docs/FLUTTER_CLIENT.md#本次同步新增接口与行为)。WebView 平台插件需满足当前直接依赖的最低版本要求。

1.3.0 的 Android 缓存、共享查询和旧快照迁移说明见 [合并与接入说明](docs/ANDROID_MERGE_1_3.md)。

## 结构化商品价格

支持两端共有的金额、币种、计费周期和适用收费阶段，见 [接入说明](protocol/SUBSCRIPTION_PRICING.md)。旧商品字段保持兼容。

Android 可使用 SDK 默认 `PaywallGooglePlayPurchaseBridge` 自动查询适用优惠、注入收费阶段并购买同一方案；仅需连接已有验单回调，详见 [共有商品协议](protocol/SUBSCRIPTION_PRICING.md)。依赖审查与兼容范围见 [Android Billing 接入](docs/ANDROID_BILLING.md)。

资源下载按包复用后台校验工作者，磁盘包复验在后台 isolate 执行。自动容量清理不阻塞资源交付，`await cache.clear()` 仍等待清理完成并保护活跃租约。默认查询批次借出下载租约供归档使用，复制目标和跨启动读取仍完整校验；自定义加载器沿用原有 `load` 路径。

唯一配置请求可与启动缓存恢复重叠；响应必须等启动版本冻结后才应用，同查询内别名点位共享归档结果，仍独立检查当前商品目录及提交索引。复用不跨查询或启动，版本、环境、归因和失败回退规则保持不变。

常驻预热通过商品状态通知等待查询结束，取消、超时或销毁均解除监听。首屏与预热交接共享本页面的成功记录任务；自动回退后的新 WebView 独立记录，旧任务完成不能交接新页面。

同次加载中刚完成的本地包校验可一次性交接给 WebView，期间持有目录租约。交接对象通过参数传递并由流程/网页释放，不保存全局“验证通过”状态；已有启动快照的后续展示、重试、外部目录与完整身份不匹配仍走完整校验。自定义仓库保留 `open` 覆写行为。查询的两个加载工作者按不同包地址领取任务，同包别名逐点提交。

真机加载耗时采集与阶段判读见 [加载耗时诊断](docs/LOAD_TIMING.md)。
