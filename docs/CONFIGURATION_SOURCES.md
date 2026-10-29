# Custom configuration sources (iOS)

## Preferred: query API

`PaywallClient(query:catalog:retainedPlacements:)` owns the POST protocol and lifecycle. The host supplies endpoint, runtime environment, a cache namespace, approved resource origins, supported server-to-host placement mappings, and its registered product catalog. Optional `PaywallQueryFallback` declares the bundled resource directory and the placements that can use it; the host does not construct or refresh package stores.

```swift
let client = PaywallClient(
    query: .init(
        endpoint: URL(string: "https://api.example.com/app/paywall/query")!,
        runtimeEnvironment: .test,
        cacheNamespace: "Example.test",
        allowedOrigins: ["https://cdn.example.com"],
        placements: ["banner": "banner", "settings": "settings"],
        fallback: .init(
            placement: "settings",
            bundledDirectory: Bundle.main.resourceURL!.appendingPathComponent("Fallback"),
            fallbackPlacements: ["banner"]
        )
    ),
    catalog: { registeredCatalog },
    retainedPlacements: ["banner", "settings"]
)
// Forward the attribution provider's callback; nil + failed=false means organic.
client.reportAttribution(channel: mediaSource, failed: attributionFailed)
// Prepare at startup; existing resolve, presentation, purchase and restore APIs stay unchanged.
try await client.prepare()
```

The SDK automatically scopes the supplied cache namespace by runtime environment, so configuration, attribution and package state cannot cross environments even when a host reuses a namespace. The SDK waits up to five seconds for an unknown channel, falls back to `organic`, and persists confirmed attribution only. It gathers app version and passes system values through unchanged: `device_type` uses the same concrete hardware model identifier as the H5 environment (for example `iPhone17,1`); simulators use `SIMULATOR_MODEL_IDENTIFIER`, `language` uses `Locale.preferredLanguages.first` (for example `en-US`), and `country` uses `Storefront.current.countryCode` (for example `USA`). Missing language or country is sent as an empty string. This does not change the H5 bridge country contract. Only the query uses these wire field names.

The response adapter understands `code`, `data`, `positionKey`, `matched`, `h5Url` and `displayModeKey`. Only mapped matched placements are accepted. Package metadata determines products and revisions; full package verification precedes configuration caching. Empty/malformed business responses fail, while a nonempty list with no matched supported placements produces an empty configuration. The host excludes placements that need unsupported business policies rather than synthesizing permissions.

Attribution changes and StoreKit storefront updates invalidate subsequent configuration while keeping existing sessions frozen. UIKit foreground activation refreshes at most hourly. A successful configuration load automatically schedules the fallback package update, including when loaded via a direct resolve or disk recovery. No host foreground task, storefront callback, DTO, country table, response adapter, timer or package update call is needed. Use `client.configurationRevision` as part of a custom preload identity.

The coordinator owns and cancels observer, refresh and package-update tasks. It retains its client weakly; channel changes cannot let an old request overwrite the current snapshot. Query-specific code is internal except the declarative configuration and fallback structs and the client entry points. No attribution SDK or application-specific domain, placement or product identifier is bundled in the SDK.

## Advanced: custom configuration source

`PaywallConfigurationSource` accepts an async URLRequest factory. Existing endpoint/parameters convenience initializers continue to issue GET requests without a response adapter.

For a business POST API, supply:

- `requestIdentity`: a stable identifier covering endpoint, method, environment and the canonical request body. A digest avoids retaining request parameters in cache keys.
- `runtimeEnvironment`: explicit `test` or `production` when the request no longer carries that value in the URL.
- `responseTransform`: async conversion of a successful HTTP body to the existing web-paywall configuration JSON. The transformed configuration is validated and cached; offline reads do not rerun the network-dependent adapter.
- `isCurrentRequest`: reject a response whose host-side conditions have changed. Rejection cancels the obsolete request without reading its cache.

POST requests do not migrate legacy URL-only caches. GET sources still read their legacy cache keys. Successful history uses the supplied request identity too. A normalized empty placement/paywall map is supported to represent an explicit no-match result; business error/empty-response policy belongs in the adapter.

`WebPaywallPackageLoader.load` accepts an approved HTTPS index.html URL, environment, allowed origins and product catalog. It checks the colocated package index, validates its exact page identity, downloads and verifies all resources, and returns the remote document. It never invents a revision or product binding. The package must already be fully published. Background package validation allows up to 120 seconds per package; ordinary on-screen preparation retains its existing default timeout and the presentation deadline still controls fallback.

`PaywallClient.invalidateConfiguration()` cancels obsolete loading and clears the in-memory configuration. Waiting callers continue with the new generation; previously presented sessions retain their own immutable snapshot. The host should also include changed business conditions in its preload cache identity. `refresh()` coalesces concurrent callers and does not preserve an unrelated stale in-memory configuration on failure; the source can still recover a valid same-identity disk snapshot.

`PaywallLocalPackageStore` now accepts a nil updateURL for bundled-only or host-driven updates. `adopt(document)` verifies a complete package before atomically updating the local pointer, retaining the previous version. Scope each store by the host request identity and reuse it during the process lifetime; never repeatedly initialize a store over files held by live sessions. Published revisions must increase, and published directories must be immutable.

No H5 bridge payload or Flutter API is changed.

## Local Debug testing

`PaywallQueryConfiguration(developmentHTTPOrigin:)` explicitly permits one HTTP origin for the query, package metadata, configuration validation and fallback update path in Debug + Test only. Release or production ignores this option. Page packages still require complete resource hashes and matching product bindings. The host must supply local networking permission and deploy complete immutable packages, not source directories.

### 查询设备参数

POST 的 `conditions.os` 为 `"iOS"` 或 `"Android"`，`conditions.isPad` 为 JSON 布尔值，含义与 H5 `custom` 中的同名字段一致。iOS 自动读取设备 idiom；Flutter 使用本次查询环境中的值。完整 POST body 参与请求缓存身份。GET 请求对应使用 `os=iOS&isPad=false` 等字符串查询参数。

```json
{"conditions":{"channel":"organic","version":"1.0","device_type":"iPhone17,1","language":"en-US","country":"USA","os":"iOS","isPad":false}}
```

## 关闭远端更新，保留本地 H5

查询入口的 `PaywallQueryConfiguration.remoteUpdatesEnabled` 默认 `false`。宿主尚未获取到 `isNormal`、获取失败或结果为 `false` 时保持关闭；只有明确获取到 `true` 后，才在原 Client 上调用 `enableRemoteUpdates()`，立即启动后台配置请求及后续页面包下载，无需重建实例。已有接入若省略此参数，也不会自动联网更新。关闭后不等待网络或归因，仅恢复当前环境下已校验的完整启动缓存，并保留内置包和原有兜底规则；缺少缓存的点位不会借用其他商品或联网补齐。`prepare` 完成本地恢复后返回，缺失点位的解析返回空，由展示入口执行既有兜底。

此开关不关闭商店价格查询、资格判断、购买、恢复和宿主法律链接行为，也不是 WebView 通用断网开关。它只作用于查询入口，不改变自定义配置来源或旧 GET 接口。主动关闭更新不会发出更新成功/失败回调，也不会清除已有缓存。

`remoteUpdatesEnabled` 配置只表示初始授权，默认为 `false`；Client 的同名只读属性反映当前状态。`enableRemoteUpdates()` 为单向、幂等授权，成功或失败都不因重复调用重新查询；不提供运行中关闭接口。自定义来源和旧 GET 入口调用此方法无作用。

关闭期间 prepare/resolve 只走本地路径，不消耗首次查询机会。开启不会失效 Client 身份、配置版本、点位快照、预加载或正在展示的 H5，不触发当前页重载；已存在点位仍冻结，新包归档供下次启动使用。缺失点位按既有规则补齐，供后续入口使用；开启后新发起且无缓存的展示仍沿用原三秒等待和兜底规则。

Flutter 同一查询域（包括相同初始开关值）的 Client 共用后台任务，任一存活 Client 授权即开启该共享域，重复调用不增加请求；已释放 Client 调用无效。该授权不改变其他 Client 的网页所有权，也不切换正在展示的页面。

```dart
final query = PaywallQueryConfiguration(
  endpoint: endpoint,
  runtimeEnvironment: WebPaywallRuntimeEnvironment.production,
  cacheNamespace: 'example-app',
  allowedOrigins: allowedOrigins,
  placements: placements,
  fallback: fallback,
  remoteUpdatesEnabled: false,
);
final client = PaywallClient.query(query: query, catalog: () => catalog);
// 异步获得宿主配置后调用。
if (isNormal) client.enableRemoteUpdates();
```
