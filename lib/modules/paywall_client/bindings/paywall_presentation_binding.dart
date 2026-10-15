import 'package:get/get.dart';
import '../controllers/paywall_presentation_controller.dart';

/// 宿主页面绑定展示协调器，离开宿主时取消未提交的准备。
class PaywallPresentationBinding extends Bindings {
  PaywallPresentationBinding({this.tag});
  final String? tag;
  @override
  void dependencies() {
    Get.lazyPut<PaywallPresentationController>(
        () => PaywallPresentationController(),
        tag: tag);
  }
}
