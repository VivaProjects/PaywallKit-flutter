import Flutter
import Foundation
import StoreKit
import UIKit
import Darwin

/// 提供私有存储、设备适配信息与商店国家更新，不传入页面文案。
public final class PaywallResourcesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var storefrontTask: Task<Void, Never>?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PaywallResourcesPlugin()
        let channel = FlutterMethodChannel(name: "native_paywall/resources", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        let events = FlutterEventChannel(name: "native_paywall/storefront", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    /// 国家仅由 StoreKit 账户提供；低版本无法获取时保留空字符串。
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "storeProducts" {
            guard let arguments = call.arguments as? [String: Any],
                  let ids = arguments["productRefs"] as? [String], !ids.isEmpty, ids.count <= 100,
                  ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
                result(FlutterError(code: "products", message: "Invalid product references", details: nil)); return
            }
            guard #available(iOS 15.0, *) else {
                result(FlutterError(code: "products", message: "StoreKit 2 requires iOS 15", details: nil)); return
            }
            Task { @MainActor in
                do { result(try await PaywallStoreProducts.load(ids: ids, includesDailyPrice: arguments["includesDailyPrice"] as? Bool ?? false)) }
                catch { result(FlutterError(code: "products", message: error.localizedDescription, details: nil)) }
            }
            return
        }
        if call.method == "environment" {
            Task { @MainActor in
                var country = ""
                if #available(iOS 15.0, *) { country = await Storefront.current?.countryCode ?? "" }
                result(["language": Locale.preferredLanguages.first ?? "",
                        "deviceModel": Self.deviceModel(), "country": country,
                        "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""])
            }
            return
        }
        guard call.method == "directory" else { result(FlutterMethodNotImplemented); return }
        do {
            var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PaywallKit/PagePackagesFlutter", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            result(directory.resolvingSymlinksInPath().path)
        } catch {
            result(FlutterError(code: "cache_directory", message: error.localizedDescription, details: nil))
        }
    }

    /// 只读取硬件型号，不采集设备唯一标识。
    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    /// Dart 查询运行时按需订阅，国家变化直接使后续请求失效。
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        storefrontTask?.cancel()
        if #available(iOS 15.0, *) {
            storefrontTask = Task { @MainActor in
                for await storefront in Storefront.updates {
                    guard !Task.isCancelled else { return }
                    events(storefront.countryCode)
                }
            }
        }
        return nil
    }

    /// 宿主退出或重建引擎时取消商店监听，不向旧通道继续发事件。
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        storefrontTask?.cancel()
        storefrontTask = nil
        return nil
    }

    deinit { storefrontTask?.cancel() }
}
