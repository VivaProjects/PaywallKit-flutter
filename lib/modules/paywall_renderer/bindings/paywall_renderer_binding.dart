import 'package:get/get.dart';
import '../controllers/paywall_runtime_controller.dart';

/// 每次打开使用唯一 tag，通过 GetPage.binding 绑定生命周期。
class PaywallRendererBinding extends Bindings {
  PaywallRendererBinding(
      {required this.sessionTag, required this.createController});
  final String sessionTag;
  final PaywallRuntimeController Function() createController;

  @override
  void dependencies() {
    Get.lazyPut<PaywallRuntimeController>(createController, tag: sessionTag);
  }
}
