# iOS / Flutter SDK 能力对照

以本次工作区的 iOS SDK 源码为参照，Flutter 使用平台等价实现，不依赖或链接 iOS SDK 仓库。SwiftUI View 对应普通 Dart 控制器与 Flutter Widget，Apple 专有商店能力由 Flutter 的 iOS 插件提供。

| iOS 能力 | Flutter 实现 | 验证 |
| --- | --- | --- |
| 配置来源、GET 参数、POST 查询、请求身份隔离 | PaywallConfigurationSource、PaywallRequestParameters、PaywallClient.query | 配置/缓存测试，真实本地 HTTP 查询 |
| 归因等待、成功持久化、失败非持久化、变化刷新 | PaywallQueryAttribution、PaywallQueryRuntime | 重启读取、超时、渠道变化测试 |
| 默认机型/版本/语言/商店国家及更新 | PaywallEnvironmentProvider + 平台插件；Android 商店国家由宿主 Billing 提供 | Dart 运行时与流清理测试；原生设备未验证 |
| 点位解析、显式禁用、会话策略 | WebPaywallConfiguration、WebPaywallSessionPolicy | 引用、权限、缺失/禁用区别测试 |
| shared 发布包、实际发布 URL、完整摘要校验 | WebPaywallPackage、WebPaywallPackageLoader | shared 环境绑定与迁移地址测试 |
| 持久资源、下载并发上限、租约、LRU | WebPaywallResourceCache、WebPaywallResourceLease | 并发、损坏、清理保护、跨实例测试 |
| 内置包、更新、前版、拒绝列表、单调版本、关闭策略 | PaywallPackageArchive、PaywallLocalPackageStore | 离线提取、更新失败、禁止旧策略重开测试 |
| 最近两个成功版本、同请求同文档隔离 | PaywallHistoryStore | 成功归档、版本上限、跨请求/点位拒绝测试 |
| 当前/历史/更新/内置单向回退、总期限、重试 | PaywallFallbackContext、PaywallFlowController | 完整四段回退、取消晚到结果测试 |
| 隐藏预渲染、首屏回执、一次性消费 | PaywallPreload、PaywallPreparationView | 未显示不能购买、身份匹配及单次消费测试 |
| 常驻预热和展示后缓存、价格资格身份 | PaywallCachedPreload、Client retainedPlacements | 展示后复用/身份变更重建测试 |
| 全屏/半屏/锁定半屏/Push | PaywallPresenter、PaywallFlowView、PaywallSheetView | MaterialApp / Navigator 路由、锁定与接续测试 |
| 内容高度回执、稳定视口、宽度变化重新布局 | WebPaywallController.contentHeight、PaywallSheetController | 200ms 定高、冻结、宽度变化测试 |
| 真实退场完成、预渲染取消、后续点位 | PaywallPresentationController、PaywallHost、PaywallPresenter | 不提前创建第二墙的路由测试 |
| ready/resolved/关闭/重试/交易/错误事件 | PaywallSessionEvent | 桥接与完整会话测试 |
| StoreKit 默认价格/周期/优惠映射 | PaywallStoreKitProductMapper + PaywallStoreProducts | Dart 静态检查；StoreKit 设备调用未验证 |
| 原有语义 JSON 渲染、签名、配置缓存 | 原有 paywall_renderer 模块保留 | contract、签名互操作及回归测试 |

价格、商店权益、恢复与验单始终由宿主交易桥确认。Android 不复制 Apple 的账户管理行为；原生接口与 Widget 测试通过不代表已完成真机购买验收。

移除 GetX 后，完整回归使用普通 MaterialApp；额外覆盖嵌套 Navigator、覆盖路由保留、宿主卸载取消、隐藏准备失败、低层 WebView 与原生渲染器生命周期，并检查 SDK 依赖树不含宿主框架。
