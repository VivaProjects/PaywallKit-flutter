package com.paywallkit.native_paywall;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.Locale;

/** 保存各运行环境最近成功的商店国家，失败不清除缓存。 */
final class PaywallStoreCountryCache {
    /** 使用内存可见、异步落盘的 apply，不等待磁盘提交。 */
    static String resolve(Context context, String environment, String country) {
        SharedPreferences preferences = context.getSharedPreferences(
            "paywall_store_country_v1", Context.MODE_PRIVATE);
        String value = country == null ? "" : country.toUpperCase(Locale.ROOT);
        // 真实查询成功才替换历史值，运行环境分别保存。
        if (value.matches("[A-Z]{3}")) {
            preferences.edit().putString(environment, value).apply();
            return value;
        }
        try {
            String cached = preferences.getString(environment, "");
            return cached != null && cached.matches("[A-Z]{3}") ? cached : "";
        } catch (ClassCastException error) {
            // 损坏的偏好值视为无缓存，不影响页面准备。
            return "";
        }
    }
}
