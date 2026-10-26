import 'dart:io';

/// 保留服务端状态，区分临时网络故障与不可重试的权限或地址错误。
class PaywallHttpFailure extends HttpException {
  PaywallHttpFailure(this.statusCode) : super('Paywall HTTP $statusCode');
  final int statusCode;
}
