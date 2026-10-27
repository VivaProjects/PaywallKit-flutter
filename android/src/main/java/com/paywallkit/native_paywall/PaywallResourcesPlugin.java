package com.paywallkit.native_paywall;

import java.util.HashMap;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import android.webkit.WebView;
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi;
import java.util.Locale;
import android.os.Build;
import android.content.pm.PackageManager;
import java.io.File;
import java.io.IOException;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;

/** 返回 Android noBackupFilesDir 下的私有持久目录。 */
public final class PaywallResourcesPlugin implements FlutterPlugin, ActivityAware {
    private MethodChannel channel;
    private PaywallGooglePlayStore store;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        store = new PaywallGooglePlayStore(binding.getApplicationContext());
        channel = new MethodChannel(binding.getBinaryMessenger(), "native_paywall/resources");
        channel.setMethodCallHandler((call, result) -> {
            if (call.method.startsWith("googlePlay")) { store.handle(call, result); return; }
            if (call.method.equals("countryISO3")) {
                String code = call.argument("country");
                try {
                    result.success(code != null && code.matches("[A-Za-z]{2}")
                        ? new Locale("", code.toUpperCase(Locale.ROOT)).getISO3Country() : "");
                } catch (java.util.MissingResourceException error) {
                    result.success("");
                }
                return;
            }
            if (call.method.equals("disableLongPress")) {
                Number identifier = call.argument("identifier");
                WebView view = identifier == null ? null :
                    WebViewFlutterAndroidExternalApi.getWebView(binding, identifier.longValue());
                if (view == null) {
                    result.error("webview", "WebView unavailable", null);
                } else {
                    // 仅拦截长按；普通点击、滚动和 JS 购买桥保持原行为。
                    view.setOnLongClickListener(v -> true);
                    view.setLongClickable(false);
                    view.setHapticFeedbackEnabled(false);
                    result.success(null);
                }
                return;
            }
            if (call.method.equals("environment")) {
                HashMap<String, Object> values = new HashMap<>();
                values.put("os", "Android");
                values.put("isPad", binding.getApplicationContext().getResources()
                    .getConfiguration().smallestScreenWidthDp >= 600);
                values.put("language", Locale.getDefault().toLanguageTag());
                values.put("deviceModel", Build.MODEL);
                // 商店账户国家需由宿主 Billing 服务提供，不能用 Locale 国家冒充。
                values.put("country", "");
                try {
                    String version = binding.getApplicationContext().getPackageManager()
                        .getPackageInfo(binding.getApplicationContext().getPackageName(), 0).versionName;
                    values.put("appVersion", version == null ? "" : version);
                    result.success(values);
                } catch (PackageManager.NameNotFoundException error) {
                    result.error("environment", "Cannot read app version", null);
                }
                return;
            }
            if (!call.method.equals("directory")) {
                result.notImplemented();
                return;
            }
            File root = new File(binding.getApplicationContext().getNoBackupFilesDir(), "paywall-packages");
            if (!root.isDirectory() && !root.mkdirs()) {
                result.error("cache_directory", "Cannot create resource directory", null);
                return;
            }
            try {
                result.success(root.getCanonicalPath());
            } catch (IOException error) {
                result.error("cache_directory", error.getMessage(), null);
            }
        });
    }

    @Override public void onAttachedToActivity(ActivityPluginBinding binding) { store.setActivity(binding.getActivity()); }
    @Override public void onDetachedFromActivityForConfigChanges() { store.setActivity(null); }
    @Override public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { store.setActivity(binding.getActivity()); }
    @Override public void onDetachedFromActivity() { if (store != null) store.setActivity(null); }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        store.close();
        store = null;
        channel.setMethodCallHandler(null);
        channel = null;
    }
}
