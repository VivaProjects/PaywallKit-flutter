# native_paywall Flutter SDK

独立 Flutter SDK 仓库。根目录即 Flutter package，包含 Dart/GetX 实现、Android/iOS 原生插件、资源、测试和协议快照；不依赖 iOS PaywallKit 或 H5 管理项目。

## 接入

本地开发指向本目录：

```yaml
dependencies:
  native_paywall:
    path: ../flutter
```

发布到独立 Git 仓库后：

```yaml
dependencies:
  native_paywall:
    git:
      url: <FLUTTER_SDK_GIT_URL>
      ref: 0.1.0
```

包已经位于仓库根目录，无需 Git `path` 字段。替换真实 URL，并使用实际已发布标签。当前配置保留 `publish_to: none`，支持 Git 发布与接入，不代表已具备 pub.dev 公共发布条件。

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
