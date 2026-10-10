import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/vps_setup.dart';

void main() {
  test('accepts public ipv4', () {
    expect(publicIpv4('203.0.113.10'), '203.0.113.10');
    expect(publicIpv4(' https://8.8.8.8:22 '), '8.8.8.8');
  });

  test('rejects private and junk', () {
    expect(publicIpv4('127.0.0.1'), isNull);
    expect(publicIpv4('192.168.1.1'), isNull);
    expect(publicIpv4('10.0.0.1'), isNull);
    expect(publicIpv4('example.com'), isNull);
    expect(publicIpv4(''), isNull);
  });

  test('maps remote install errors', () {
    expect(describeRemoteInstall('python3: command not found'), contains('python3'));
    expect(describeRemoteInstall('landing did not listen on 8444'), contains('8444'));
    expect(describeRemoteInstall('E: Could not get lock /var/lib/dpkg/lock'), contains('稍等'));
  });
}
