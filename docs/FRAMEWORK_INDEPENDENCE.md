# SDK 框架独立性与迁移

1.0.0 移除 GetX，包含不兼容的公开 API 变更。0.2.0 标签保留原实现；使用本页 API 时，将 Git ref 更新到 1.0.0，并按下表迁移。

SDK 只使用 Dart/Flutter 标准状态与导航能力。宿主可以使用任意应用框架，SDK 不要求修改应用根节点或注册全局服务。购买、恢复、商店价格和资格、H5 协议及离线包格式保持兼容。

## 从 0.2.0 迁移

| 旧接口 | 当前接口 |
| --- | --- |
| PaywallFlowBinding、PaywallPresentationBinding | 直接构造控制器并通过 controller 参数传入 |
| WebPaywallBinding、PaywallRendererBinding、sessionTag | WebPaywallView / PaywallRendererView 的 controller 参数 |
| PaywallSessionBinding | PaywallSessionFactory.createController()，返回实例传给视图 |
| PaywallPresenter(controller: ...) | 加上传入目标 navigator: Navigator.of(context) |
| onInit / onReady / onClose | start / dispose；视图默认自动调用 |
| Rx / Obx / ever | ValueNotifier / ValueListenableBuilder / addListener 和 removeListener |
| renderer.products 列表 | renderer.products.value，不可变列表整体替换 |

## 生命周期与所有权

- 普通控制器通过构造参数接收服务，不访问全局容器。不要在 build 内重复创建控制器。
- PaywallFlowView、WebPaywallView、PaywallRendererView 首次挂载调用 start；更换控制器或卸载时默认释放原实例。外部拥有实例时传 disposeController: false，外部必须在卸载后调用 dispose。
- PaywallPresenter 接管 create 返回的 Flow 或成功消费的预加载 Flow，并在真实路由 completed 后释放。重复展示、准备取消、异常和旧请求的晚到结果不会创建额外路由。
- PaywallPresentationController 由宿主 State 持有，State.dispose 时释放。PaywallHost 卸载会取消尚未提交的准备；销毁协调器还会关闭自己管理的已提交支付墙，并阻止下一点位接续。
- PaywallPreload 与 PaywallCachedPreload 由宿主持有；取消场景调用 cancel，卸载隐藏视图后调用 dispose。成功消费后 Flow 归展示方所有，句柄不能继续释放该 Flow。
- 保留的 WebView 归 PaywallClient 所有。退出 Flow 时不会销毁已移交的网页；invalidatePage 或 client.dispose 释放缓存。价格和资格改变仍需更新 cacheIdentity。
- 传入嵌套 Navigator 时只操作该导航栈；覆盖全应用需显式选择 rootNavigator。SDK 只关闭自己创建的路由，不弹出覆盖它的法律或业务页面。

## 防止重新引入

规则写入仓库 AGENTS.md。`flutter test test/sdk_architecture_test.dart` 检查运行时依赖白名单、生产源码导入及解析依赖中的禁止框架；完整 `flutter test` 自动执行。新增依赖必须审查它的 SDK 用途，不能通过修改白名单或关闭测试引入宿主框架。能力测试使用普通 MaterialApp，不依赖框架测试环境。

## 宿主展示控制

- `PaywallFlowController.presentationOverride` 固定当前会话展示方式，包括配置加载、回退和重试；默认沿用点位配置。改变此值时应创建新会话并更新预加载身份。
- `PaywallPresenter.present(showBackButton: true)` 为非半屏路由添加透明原生导航栏，H5 延伸到导航栏下方，返回动作遵循会话关闭权限。
- `onPresented` 在路由成功 push 后同步通知宿主，用于交接准备页；此时不保证入场动画完成。
- `PaywallFlowView(isPresented: false)` 只准备网页，不开放桥接动作；变为 true 后接管当前会话，隐藏时暂停页面动作。
- 购买和恢复处理中，网页关闭与普通原生返回均被阻止；交易结果继续交由宿主处理。
