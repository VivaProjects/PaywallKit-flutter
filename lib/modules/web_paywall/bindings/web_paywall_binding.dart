import 'package:get/get.dart';
import '../controllers/web_paywall_controller.dart';

/// 每次打开注册独立实例，由路由 Binding 统一管理生命周期。
class WebPaywallBinding extends Bindings {
  WebPaywallBinding({required this.sessionTag, required this.createController});
  final String sessionTag;
  final WebPaywallController Function() createController;

  @override
  void dependencies() {
    Get.lazyPut<WebPaywallController>(createController, tag: sessionTag);
  }
}
