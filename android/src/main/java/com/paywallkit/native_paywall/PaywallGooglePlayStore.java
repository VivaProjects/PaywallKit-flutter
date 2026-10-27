package com.paywallkit.native_paywall;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import com.android.billingclient.api.*;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.*;

/** 引擎拥有唯一 BillingClient；每个 Dart 桥有独立报价和显式释放时机。 */
final class PaywallGooglePlayStore implements PurchasesUpdatedListener {
    private final BillingClient client;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, Map<String, ProductDetails>> quotes = new HashMap<>();
    private final Set<Request> requests = new HashSet<>();
    private final List<Runnable> connecting = new ArrayList<>();
    private boolean starting, closed, purchaseInFlight;
    private Activity activity;
    private Request purchaseRequest;
    private String purchaseProduct;

    PaywallGooglePlayStore(Context context) {
        client = BillingClient.newBuilder(context).setListener(this)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build())
            .enableAutoServiceReconnection().build();
    }

    void setActivity(Activity value) { activity = value; }

    /** 每个请求均有限时和完成门禁，释放后到达的异步结果不再写入会话。 */
    private final class Request {
        final String owner;
        final MethodChannel.Result result;
        boolean done;
        final Runnable timeout = () -> {
            error("billing_timeout", "Google Play request timed out");
            if (requests.isEmpty() && starting) { connecting.clear(); starting = false; }
        };
        Request(String owner, MethodChannel.Result result, long timeoutMs) {
            this.owner = owner; this.result = result;
            requests.add(this); main.postDelayed(timeout, timeoutMs);
        }
        void success(Object value) {
            if (finish()) result.success(value);
        }
        void error(String code, String message) {
            if (finish()) result.error(code, message, null);
        }
        boolean finish() {
            if (done) return false;
            done = true; main.removeCallbacks(timeout); requests.remove(this);
            if (purchaseRequest == this) { purchaseRequest = null; purchaseProduct = null; }
            return true;
        }
        boolean check(BillingResult value) {
            if (done) return false;
            if (value.getResponseCode() == BillingClient.BillingResponseCode.OK) return true;
            error("billing_" + value.getResponseCode(), value.getDebugMessage()); return false;
        }
    }

    void handle(MethodCall call, MethodChannel.Result result) {
        String owner = call.argument("owner");
        if (owner == null || owner.isEmpty() || closed) {
            result.error("billing_owner", "Invalid or disposed billing owner", null); return;
        }
        if (call.method.equals("googlePlayDispose")) {
            quotes.remove(owner);
            for (Request request : new ArrayList<>(requests)) {
                if (request.owner.equals(owner)) request.error("billing_disposed", "Billing owner disposed");
            }
            result.success(null); return;
        }
        if (!quotes.containsKey(owner)) quotes.put(owner, new HashMap<>());
        Request request = new Request(owner, result, call.method.equals("googlePlayPurchase") ? 300000 : 30000);
        ready(request, () -> {
            if (request.done) return;
            try {
                switch (call.method) {
                    case "googlePlayProducts": query(call, request); break;
                    case "googlePlayPurchase": purchase(call, request); break;
                    case "googlePlayRestore": restore(request); break;
                    case "googlePlayAcknowledge": acknowledge(call, request); break;
                    default: request.error("billing_method", "Unsupported billing operation");
                }
            } catch (RuntimeException error) {
                request.error("billing_arguments", "Invalid billing request");
            }
        });
    }

    /** 并发查询共享连接；连接失败结束所有等待请求，不循环重试。 */
    private void ready(Request request, Runnable action) {
        if (client.isReady()) { action.run(); return; }
        connecting.add(action);
        if (starting) return;
        starting = true;
        try { client.startConnection(new BillingClientStateListener() {
            @Override public void onBillingSetupFinished(BillingResult result) {
                main.post(() -> {
                    starting = false;
                    List<Runnable> pending = new ArrayList<>(connecting); connecting.clear();
                    if (closed) return;
                    if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                        for (Request item : new ArrayList<>(requests)) item.check(result);
                    } else for (Runnable run : pending) run.run();
                });
            }
            @Override public void onBillingServiceDisconnected() { /* 后续请求由 Billing 自动重连。 */ }
        }); } catch (RuntimeException error) {
            starting = false; connecting.clear();
            for (Request item : new ArrayList<>(requests)) item.error("billing_connection", "Cannot connect to Google Play");
        }
    }

    private interface ProductsCallback { void accept(List<ProductDetails> products); }

    private void fetch(List<String> ids, Request request, ProductsCallback success) {
        List<QueryProductDetailsParams.Product> products = new ArrayList<>();
        for (String id : ids) products.add(QueryProductDetailsParams.Product.newBuilder()
            .setProductId(id).setProductType(BillingClient.ProductType.SUBS).build());
        client.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(products).build(),
            (result, values) -> main.post(() -> {
                if (!request.check(result)) return;
                try { success.accept(values.getProductDetailsList()); }
                catch (RuntimeException error) { request.error("billing_response", "Cannot process store response"); }
            }));
    }

    private void query(MethodCall call, Request request) {
        List<String> ids = call.argument("productRefs");
        if (ids == null || ids.isEmpty() || ids.size() > 100 || new HashSet<>(ids).size() != ids.size()) {
            request.error("billing_products", "Invalid product references"); return;
        }
        for (String id : ids) if (id == null || id.isEmpty()) {
            request.error("billing_products", "Invalid product ID"); return;
        }
        fetch(ids, request, products -> {
            if (products.size() != ids.size()) {
                request.error("billing_products", "Some subscriptions could not be fetched"); return;
            }
            List<Map<String, Object>> output = new ArrayList<>();
            Map<String, ProductDetails> cache = quotes.get(request.owner);
            // 不无限持有商店对象；旧产品超过上限会要求页面重新查询。
            if (cache.size() + products.size() > 200) cache.clear();
            for (ProductDetails product : products) {
                String quoteId = UUID.randomUUID().toString();
                cache.put(quoteId, product);
                output.add(PaywallGooglePlayData.product(product, quoteId));
            }
            request.success(output);
        });
    }

    /** 购买前重新查询，价格、优惠资格或 token 变化时拒绝旧报价，不静默切正常价。 */
    private void purchase(MethodCall call, Request request) {
        if (purchaseRequest != null || purchaseInFlight || activity == null) {
            request.error("billing_busy", "Purchase active or activity unavailable"); return;
        }
        String quoteId = call.argument("quoteId"), token = call.argument("offerToken");
        ProductDetails quoted = quotes.get(request.owner).get(quoteId);
        ProductDetails.SubscriptionOfferDetails offer = quoted == null ? null : PaywallGooglePlayData.findOffer(quoted, token);
        if (offer == null) { request.error("billing_quote", "Quote unavailable; reload products"); return; }
        purchaseRequest = request; purchaseProduct = quoted.getProductId();
        fetch(Collections.singletonList(quoted.getProductId()), request, products -> {
            ProductDetails fresh = products.size() == 1 ? products.get(0) : null;
            ProductDetails.SubscriptionOfferDetails current = fresh == null ? null : PaywallGooglePlayData.findOffer(fresh, token);
            if (current == null || !PaywallGooglePlayData.offer(current).equals(PaywallGooglePlayData.offer(offer))) {
                request.error("billing_quote_changed", "Subscription offer changed; reload products"); return;
            }
            if (activity == null) { request.error("billing_activity", "Activity unavailable"); return; }
            BillingFlowParams.ProductDetailsParams params = BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(fresh).setOfferToken(token).build();
            purchaseInFlight = true;
            BillingResult launched = client.launchBillingFlow(activity, BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(Collections.singletonList(params)).build());
            if (!request.check(launched)) purchaseInFlight = false;
        });
    }

    @Override public void onPurchasesUpdated(BillingResult result, List<Purchase> purchases) {
        main.post(() -> {
            purchaseInFlight = false;
            Request request = purchaseRequest;
            if (request == null || request.done) return;
            if (result.getResponseCode() == BillingClient.BillingResponseCode.USER_CANCELED) {
                request.success(Collections.singletonMap("cancelled", true)); return;
            }
            if (!request.check(result)) return;
            if (purchases != null) for (Purchase purchase : purchases) {
                if (purchase.getProducts().contains(purchaseProduct)) {
                    if (purchase.getPurchaseState() != Purchase.PurchaseState.PURCHASED &&
                        purchase.getPurchaseState() != Purchase.PurchaseState.PENDING) {
                        request.error("billing_purchase", "Unknown purchase state"); return;
                    }
                    request.success(PaywallGooglePlayData.purchase(purchase)); return;
                }
            }
            request.error("billing_purchase", "No matching subscription purchase");
        });
    }

    /** 恢复只返回持有的订阅，权益有效性仍必须由宿主验单。 */
    private void restore(Request request) {
        client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
            (result, purchases) -> main.post(() -> {
                if (!request.check(result)) return;
                List<Map<String, Object>> values = new ArrayList<>();
                for (Purchase purchase : purchases) {
                    if (purchase.getPurchaseState() == Purchase.PurchaseState.PURCHASED ||
                        purchase.getPurchaseState() == Purchase.PurchaseState.PENDING) values.add(PaywallGooglePlayData.purchase(purchase));
                }
                request.success(values);
            }));
    }

    private void acknowledge(MethodCall call, Request request) {
        String token = call.argument("purchaseToken");
        if (token == null || token.isEmpty()) { request.error("billing_token", "Missing purchase token"); return; }
        client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build(),
            result -> main.post(() -> { if (request.check(result)) request.success(null); }));
    }

    void close() {
        closed = true; activity = null; connecting.clear(); quotes.clear();
        for (Request request : new ArrayList<>(requests)) request.error("billing_disposed", "Engine detached");
        client.endConnection();
    }
}
