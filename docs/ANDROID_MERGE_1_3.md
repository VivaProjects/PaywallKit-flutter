# 1.3.0 Android 功能合并

## 接入

使用独立 Git 仓库标签 `1.3.0`，包入口位于根目录；无需本地源码副本。本版本不新增运行时依赖，不要求宿主使用任何状态管理或路由框架。

保留 1.2.0 的 `os` / `isPad` 采集、查询和 H5 注入，临时隐藏保留回调，以及 `onPresented` 观察者异常隔离。

## 可选能力

- `client.residentPlacements`：指定 Android 常驻 WebView 的点位；仅全屏及 push 使用，默认关闭。会话销毁时释放表面，路由覆盖时隐藏。
- `PaywallFlowController.refreshProductsAfterReuse`：缓存先展示、后台核对完整报价。核对期间禁止交易，变化或失败重建页面，默认关闭。
- `PaywallQueryConfiguration.waitUntilNetworkAvailableCancellable`：接收取消 Future；最后一个共享 Client 释放时结束等待。原无参数 `waitUntilNetworkAvailable` 继续支持，两者同时配置时优先可取消版本。
- `legacyCacheNamespaces`、`fetch`、`packageLoader` 支持旧配置迁移和可注入的传输、包加载。
- `restoreQuery()` 只恢复磁盘；`waitForQueryUpdate()` 等待本次唯一更新，不追加查询。
- `PaywallPurchaseCapabilities` 保留兼容声明；新接入优先使用 `PaywallStoreActionPolicy`。

相同查询域、端点、点位映射及来源限制共享运行时。调用者必须为不同业务配置使用不同 `cacheNamespace`；共享域应使用一致的环境提供者、目录和存储。各 Client 的页面缓存与兜底授权保持独立。最后一个 Client 释放后结束共享会话；测试模拟新启动时应先释放上一次启动的 Client。

## 行为修复

锁定半屏阻止系统返回、遮罩和拖动关闭，但在已展示、宿主授权且无交易时接受 H5 明确关闭。半屏背景延伸至系统导航区域，H5 前景控件应自行避让安全区。网页纵向滚动保留自身手势。

归档默认复用共享资源缓存，避免独立实例清理彼此在途下载。预加载等待商品门禁解除才缓存；桥接同步真实可见状态及交易权限。Android `countryISO3` 仅转换宿主传入的真实商店国家码，不使用设备地区推断。

配置解析上限从 8 页增至 16 页。查询严格验证信封及重复点位；仅明确未命中删除下次启动缓存，网络与包错误保留旧缓存。

## 缓存与协议

新快照按环境命名空间、端点、版本、机型、语言、系统及平板标识隔离。无新索引时尝试读取旧独立 SDK `records` 和 Android `placements` 索引，复验适配条件、商品目录、来源和完整资源后复制归档；迁移不触发下载。损坏或不匹配条目等待后台查询或内置兜底。

已有点位本次启动冻结，后台更新下次启动使用。快照格式兼容迁移不等于支持跨版本降级共享缓存。桥协议版本未增加，新增 `allowsStoreActions` 和可见性消息属于兼容元数据，H5 不能据此决定真实交易资格。没有修改其他 SDK 或 H5 项目。

## 本次验证边界

遵循本次任务仅静态验证的限制：执行格式、Flutter 静态分析、包独立性及版本一致性检查。新增共享查询、离线迁移、适配参数恢复、锁定半屏关闭回归，并调整启动模拟测试；未执行 flutter test、运行时协议脚本、应用、原生构建或真机交易验证。本次 Git 标签发布不代表上述运行验证已完成。
