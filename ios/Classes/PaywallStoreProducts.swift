import Foundation
import StoreKit

/// StoreKit 默认价格转换器；购买、恢复与权益验证仍由宿主实现。
@available(iOS 15.0, *)
enum PaywallStoreProducts {
    /// 只查询宿主明确传入的商店 ID，不接受网页决定商品查询范围。
    static func load(ids: [String], includesDailyPrice: Bool) async throws -> [[String: Any]] {
        let products = try await Product.products(for: ids)
        var values: [[String: Any]] = []
        for product in products {
            values.append(await map(product, includesDailyPrice: includesDailyPrice))
        }
        return values
    }

    /// 价格、周期和优惠资格全部来自 StoreKit，不解析 H5 文案。
    private static func map(_ product: Product, includesDailyPrice: Bool) async -> [String: Any] {
        let period = product.subscription?.subscriptionPeriod
        let renewal = period.map { "\(product.displayPrice) / \(periodText($0))" } ?? product.displayPrice
        var offer: Product.SubscriptionOffer?
        if let subscription = product.subscription, await subscription.isEligibleForIntroOffer {
            offer = subscription.introductoryOffer
        }
        let disclosure: String
        if let offer {
            disclosure = "\(introductoryText(offer)), then renews at \(renewal). Cancel anytime in your Apple account."
        } else if period != nil {
            disclosure = "Automatically renews at \(renewal). Cancel anytime in your Apple account."
        } else { disclosure = product.displayPrice }
        var result: [String: Any] = ["productRef": product.id, "storeProductId": product.id,
            "title": product.displayName, "displayPrice": product.displayPrice,
            "disclosure": disclosure, "isEligibleForFreeTrial": offer?.paymentMode == .freeTrial]
        if let period { result["periodText"] = periodText(period) }
        if let offer { result["introductoryPriceText"] = offer.displayPrice }
        if includesDailyPrice, let period, period.unit == .year, period.value > 0 {
            result["dailyPriceText"] = (product.price / Decimal(365 * period.value)).formatted(product.priceFormatStyle)
        }
        if let phases = PaywallStoreKitPricing.phases(product, eligibleOffer: offer) {
            result["subscriptionPricing"] = ["phases": phases]
        }
        return result
    }

    /// 周期使用商店单位，未知单位保留通用周期说明。
    private static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return "\(period.value) \(unit)\(period.value == 1 ? "" : "s")"
    }

    /// 只有确认资格后的优惠才进入价格披露。
    private static func introductoryText(_ offer: Product.SubscriptionOffer) -> String {
        let duration = periodText(offer.period)
        switch offer.paymentMode {
        case .freeTrial: return "Free for \(duration)"
        case .payAsYouGo: return "\(offer.displayPrice) per \(duration) for \(offer.periodCount) periods"
        case .payUpFront: return "\(offer.displayPrice) for \(duration)"
        default: return "Introductory offer \(offer.displayPrice)"
        }
    }
}
