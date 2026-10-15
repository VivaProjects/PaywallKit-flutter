import 'package:get/get.dart';
import '../controllers/paywall_flow_controller.dart';

/// 高层会话由展示路由管理，准备完成的同一实例只交接一次。
class PaywallFlowBinding extends Bindings {
  PaywallFlowBinding({required this.tag, required this.controller});
  final String tag;
  final PaywallFlowController controller;

  /// View 不注册依赖，路由释放时自动清理当前会话。
  @override
  void dependencies() {
    Get.lazyPut<PaywallFlowController>(() => controller, tag: tag);
  }
}
