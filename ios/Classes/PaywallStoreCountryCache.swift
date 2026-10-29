import Foundation

/// Flutter SDK 独立保存各运行环境最近成功的商店国家。
enum PaywallStoreCountryCache {
    /// 空结果不覆盖历史成功值；系统偏好异步落盘，不强制同步磁盘。
    static func resolve(_ country: String, environment: String) -> String {
        let key = "PaywallKit.flutter.storeCountry.v1.\(environment)"
        let value = country.uppercased()
        // 只保存符合桥协议的商店国家，失败时读取已有记录。
        if valid(value) {
            UserDefaults.standard.set(value, forKey: key)
            return value
        }
        let cached = UserDefaults.standard.string(forKey: key) ?? ""
        return valid(cached) ? cached : ""
    }

    /// 拒绝非法缓存内容进入 H5 环境。
    private static func valid(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
    }
}
