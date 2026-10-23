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
      ref: 1.2.0
```

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
