import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/bypass.dart';

void main() {
  test('normalizes urls into hosts', () {
    expect(normalizeBypassHost('https://Baidu.com/path'), 'baidu.com');
    expect(normalizeBypassHost('*.qq.com'), 'qq.com');
    expect(normalizeBypassHost('www.bilibili.com:443'), 'www.bilibili.com');
    expect(normalizeBypassHost('8.8.8.8'), '8.8.8.8');
    expect(normalizeBypassHost('not a host'), isNull);
    expect(normalizeBypassHost('localhost'), isNull);
  });

  test('matches domain and subdomains', () {
    expect(hostBypasses('baidu.com', ['baidu.com']), isTrue);
    expect(hostBypasses('www.baidu.com', ['baidu.com']), isTrue);
    expect(hostBypasses('google.com', ['baidu.com']), isFalse);
  });
}
