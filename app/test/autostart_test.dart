import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/autostart.dart';

void main() {
  test('autostart reports platform support', () {
    // 单测环境一般不是正式安装路径，只验证 API 可调用。
    expect(Autostart.supported, isA<bool>());
  });
}
