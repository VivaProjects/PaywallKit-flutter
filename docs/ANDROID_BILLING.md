# Android 默认订阅桥

`PaywallGooglePlayPurchaseBridge` 是 SDK 自带的 Android `PaywallPurchaseBridge` 实现。H5 绑定一个商店订阅 ID，SDK 查询当前 Play 返回的可用方案，自动选中优惠或正常方案，通过已有商品桥传递 `subscriptionPricing`。不需要 `custom.hasOffer`、历史优惠标记或宿主手工注入商品报价。

## 接入与购买一致性

```dart
final bridge = PaywallGooglePlayPurchaseBridge(
  verifyPurchase: (purchase) async {
    // 宿主既有后端验证并发放权益；该回调不负责优惠查询或选择。
    // 核对 package、productIds、账户归属、purchaseToken、有效期等。
    return verifyAndGrantEntitlement(purchase);
  },
);
```

把桥传给现有 SDK 支付墙入口。实例由创建者持有，支付墙会话销毁后 `await bridge.dispose()`。在重新进入或应用恢复时调用 `restore()` 验证延迟完成/未确认的订阅。`restore()` 会查询当前持有的所有订阅，宿主验证回调必须核对其是否属于本应用可授予的权益，不可只判断 token 非空。

- 一个商品只有一个可用基础套餐时：优先选 Play 返回的优惠；没有优惠选正常套餐。同套餐多个可用优惠按 offerId 字典序选择，稳定但不保证最便宜。
- 多基础套餐不猜测、不选数组第一项；会报错要求调整商品配置。分期计划不会被简化成普通订阅。默认不实现升级/降级替换。
- 只支持 Play 管理资格的优惠。开发者自定义资格不能从 ProductDetails 自动推断，不能用于此默认桥；这类场景仍需专用原生实现，不得在 H5 判断。
- Dart 内部把不可变商品对象绑定到本次报价身份，H5 不接收 quoteId、offerToken 或交易凭证。
- 购买前原生重新查询并核对选定 token 和全部价格阶段；变化报 `billing_quote_changed`，须重新加载报价。不得静默切换正常价购买。
- Play 最终确认界面仍会再次判断交易资格。SDK 不控制该商店界面，也不能保证查询后商店状态不变。
- pending/取消不发放权益；只有宿主验证回调确认权益后才 acknowledge、返回 succeeded。验单与交易确认必须采用幂等逻辑，避免和旧购买处理器重复处理。
- 查询等操作 30 秒超时，购买回调等待 5 分钟。释放实例使迟到结果失效；已经打开的 Play 购买界面无法由 dispose 撤销，后续通过 restore 恢复。

## 新增依赖审查

新增原生依赖 `com.android.billingclient:billing:8.0.0`，承载真实商店查询、优惠返回、购买和确认交易。选择 8.0.0 是为了保持 SDK 既有 minSdk 21；8.1 起要求 minSdk 23。没有新增 Dart 运行时依赖，也没有引入 Flutter 状态管理、路由、DI 框架或全局服务定位器。

已读取 Google Maven 的 8.0.0 官方 POM。直接依赖为 AndroidX Activity 1.2.3、Google DataTransport API 3.0.0 / CCT 与 Runtime 3.1.8，以及 Play Services base 18.5.0、basement 18.4.0、location 19.0.0、tasks 18.2.0。这些是官方 Billing 的原生传递依赖，不要求宿主采用特定 Flutter 架构；SDK 不调用定位 API。宿主最终 Gradle 版本冲突解析仍需在应用集成时核对。

递归审查官方 Maven POM 共 69 个坐标版本，未出现未解析节点；传递依赖为 AndroidX 基础组件、Google Play Services / DataTransport / Firebase 编码工具及 javax.inject 注解。这里是 POM 声明依赖树审查，不是宿主 Gradle 冲突解析后的最终依赖图。

架构测试继续执行原有 Flutter 依赖白名单，并新增 Android Maven 直接依赖白名单检查。没有放宽或删除框架禁止规则。

## 验证边界

覆盖自动首月优惠、无优惠、免费试用、多基础套餐拒绝、同基础套餐多优惠稳定选择、旧报价对象保护、原生报价变化错误、pending/取消、验单失败、恢复、释放后迟到响应和交易互斥的 Dart 通道测试。另检查已有结构化商品、握手和缓存回归。

2026-10-27 发布检查已通过 Android 原生插件编译；未执行真实商店购买。应用上线前仍需用 Play 测试账号验证新用户、已用过优惠用户、不同商店币种、购买取消、延迟付款、恢复和页面退出。Dart mock 通道测试不代表原生 Billing 真机流程已通过。

官方资料：[Billing 集成](https://developer.android.com/google/play/billing/integrate)、[版本及最低系统要求](https://developer.android.com/google/play/billing/release-notes)、[Billing 8.0.0 POM](https://dl.google.com/dl/android/maven2/com/android/billingclient/billing/8.0.0/billing-8.0.0.pom)。
