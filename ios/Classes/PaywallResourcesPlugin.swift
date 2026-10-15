import Flutter
import Foundation

/// 仅提供排除备份的私有路径，不接触页面数据或交易。
public final class PaywallResourcesPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "native_paywall/resources", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(PaywallResourcesPlugin(), channel: channel)
    }

    /// 持久资源可重新下载，因此排除 iCloud 与设备备份。
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
}
