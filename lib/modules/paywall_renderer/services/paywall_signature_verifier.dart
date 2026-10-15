import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashes;

class PaywallSignatureVerifier {
  const PaywallSignatureVerifier(this.publicKeys);
  final Map<String, List<int>> publicKeys;

  /// 使用宿主内置公钥，对传输的原始 payload 字节验签。
  Future<List<int>> payload(List<int> data) async {
    if (data.length > 400000) throw const FormatException('envelope_size');
    final envelope = jsonDecode(utf8.decode(data));
    final key = publicKeys[envelope['keyId']];
    if (key == null || envelope['algorithm'] != 'Ed25519')
      throw const FormatException('unknown_key_or_algorithm');
    final bytes = base64Decode(envelope['payload']);
    if (bytes.length > 262144) throw const FormatException('payload_size');
    final valid = await Ed25519().verify(bytes,
        signature: Signature(base64Decode(envelope['signature']),
            publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)));
    if (!valid) throw const FormatException('signature_invalid');
    return bytes;
  }

  String digest(List<int> data) => hashes.sha256.convert(data).toString();

  /// 与 Swift 一致，哈希前四字节大端取模生成粘性分桶。
  int bucket(String installationId, String experimentId) {
    final hash = hashes.sha256
        .convert(utf8.encode('$installationId|$experimentId'))
        .bytes;
    return ((hash[0] << 24) | (hash[1] << 16) | (hash[2] << 8) | hash[3]) %
        10000;
  }
}
