package com.paywallkit.native_paywall;

import com.android.billingclient.api.*;
import java.util.*;

/** 只转换商店原始字段；购买令牌只留在原生与 Dart 之间，不进入 H5。 */
final class PaywallGooglePlayData {
    static Map<String, Object> product(ProductDetails product, String quoteId) {
        Map<String, Object> value = new HashMap<>();
        value.put("productId", product.getProductId());
        value.put("title", product.getTitle());
        value.put("quoteId", quoteId);
        List<Map<String, Object>> offers = new ArrayList<>();
        if (product.getSubscriptionOfferDetails() != null) {
            for (ProductDetails.SubscriptionOfferDetails offer : product.getSubscriptionOfferDetails()) {
                // 分期订阅有额外承诺条件，默认桥不支持，不能简化成普通订阅。
                if (offer.getInstallmentPlanDetails() == null) offers.add(offer(offer));
            }
        }
        value.put("offers", offers);
        return value;
    }

    static Map<String, Object> offer(ProductDetails.SubscriptionOfferDetails offer) {
        Map<String, Object> value = new HashMap<>();
        value.put("basePlanId", offer.getBasePlanId());
        value.put("offerId", offer.getOfferId());
        value.put("offerToken", offer.getOfferToken());
        List<Map<String, Object>> phases = new ArrayList<>();
        for (ProductDetails.PricingPhase phase : offer.getPricingPhases().getPricingPhaseList()) {
            Map<String, Object> item = new HashMap<>();
            item.put("priceAmountMicros", phase.getPriceAmountMicros());
            item.put("priceCurrencyCode", phase.getPriceCurrencyCode());
            item.put("formattedPrice", phase.getFormattedPrice());
            item.put("billingPeriod", phase.getBillingPeriod());
            item.put("billingCycleCount", phase.getBillingCycleCount());
            item.put("recurrenceMode", phase.getRecurrenceMode());
            phases.add(item);
        }
        value.put("phases", phases);
        return value;
    }

    static Map<String, Object> purchase(Purchase purchase) {
        Map<String, Object> value = new HashMap<>();
        value.put("productIds", purchase.getProducts());
        value.put("purchaseToken", purchase.getPurchaseToken());
        value.put("originalJson", purchase.getOriginalJson());
        value.put("signature", purchase.getSignature());
        value.put("acknowledged", purchase.isAcknowledged());
        value.put("pending", purchase.getPurchaseState() == Purchase.PurchaseState.PENDING);
        return value;
    }

    static ProductDetails.SubscriptionOfferDetails findOffer(ProductDetails product, String token) {
        if (product.getSubscriptionOfferDetails() == null) return null;
        for (ProductDetails.SubscriptionOfferDetails offer : product.getSubscriptionOfferDetails()) {
            if (offer.getOfferToken().equals(token) && offer.getInstallmentPlanDetails() == null) return offer;
        }
        return null;
    }
}
