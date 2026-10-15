package com.paywallkit.native_paywall;

import java.io.File;
import java.io.IOException;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;

/** 返回 Android noBackupFilesDir 下的私有持久目录。 */
public final class PaywallResourcesPlugin implements FlutterPlugin {
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "native_paywall/resources");
        channel.setMethodCallHandler((call, result) -> {
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

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }
}
