import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/autostart.dart';
import 'package:rsq/system_proxy.dart';

void main() {
  test('gnome ignore list keeps localhost and wildcard domains', () {
    final text = SystemProxy.gnomeIgnoreHosts(['baidu.com', '10.0.0.1', '']);
    expect(text, contains("'localhost'"));
    expect(text, contains("'127.0.0.1'"));
    expect(text, contains("'baidu.com'"));
    expect(text, contains("'*.baidu.com'"));
    expect(text, contains("'10.0.0.1'"));
    expect(text, isNot(contains("'*.10.0.0.1'")));
    expect(SystemProxy.gnomeUnquote("'manual'"), 'manual');
    expect(SystemProxy.gnomeUnquote('8080'), '8080');
  });

  test('kde proxy file only replaces our section', () {
    const other = '[Browser Settings]\nOpenLinks=true\n\n[Proxy Settings]\nProxyType=1\nhttpProxy=http://10.0.0.1:8080\n';
    expect(SystemProxy.rewriteKdeProxyFile(other, enable: false, httpPort: 8080), other);

    const ours = '[Browser Settings]\nOpenLinks=true\n\n[Proxy Settings]\nProxyType=1\nhttpProxy=http://127.0.0.1:8080\n';
    final cleared = SystemProxy.rewriteKdeProxyFile(ours, enable: false, httpPort: 8080);
    expect(cleared, contains('[Browser Settings]'));
    expect(cleared, contains('OpenLinks=true'));
    expect(cleared, contains('ProxyType=0'));
    expect(cleared, contains('http://127.0.0.1:8080'));

    final enabled = SystemProxy.rewriteKdeProxyFile(
      '[Other]\nA=1\n',
      enable: true,
      httpPort: 8080,
      socksPort: 1080,
      noProxy: SystemProxy.kdeNoProxy(['baidu.com']),
    );
    expect(enabled, contains('[Other]'));
    expect(enabled, contains('A=1'));
    expect(enabled, contains('httpProxy=http://127.0.0.1:8080'));
    expect(enabled, contains('socksProxy=socks://127.0.0.1:1080'));
    expect(enabled, contains('*.baidu.com'));
    expect(SystemProxy.kdeProxyIsLocal({'ProxyType': '0', 'httpProxy': 'http://127.0.0.1:8080'}), isFalse);
  });

  test('linux autostart escapes the executable path', () {
    expect(Autostart.desktopExec(r'/home/a b/tiaotiaohou'), r'/home/a\ b/tiaotiaohou');
    final entry = Autostart.linuxAutostartEntry('/opt/tiaotiaohou');
    expect(entry, contains('Exec=/opt/tiaotiaohou --quiet'));
    expect(entry, contains('X-GNOME-Autostart-enabled=true'));
  });
}
