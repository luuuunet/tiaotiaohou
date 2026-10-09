import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/flags.dart';
import 'package:rsq/nodes.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates the old single node', () async {
    SharedPreferences.setMockInitialValues({
      'endpoint': 'https://vpn.example.com',
      'token': 'abc',
      'node_name': '家里',
      'exit_via': 'landing',
      'vps_ip': '203.0.113.8',
    });
    final book = await NodeBook.load();
    expect(book.nodes, hasLength(1));
    expect(book.active?.name, '家里');
    expect(book.active?.vpsIp, '203.0.113.8');
    expect(book.active?.udp, isTrue);
  });

  test('keeps many nodes and selects one', () async {
    SharedPreferences.setMockInitialValues({});
    final book = await NodeBook.load();
    book.put(name: '公司', endpoint: 'https://a.example.com', token: 't1', exitVia: 'direct');
    book.put(name: '备用', endpoint: 'https://b.example.com', token: 't2', exitVia: 'landing', vpsIp: '8.8.8.8');
    expect(book.nodes, hasLength(2));
    expect(book.active?.name, '备用');
    book.select(book.nodes.first.id);
    expect(book.active?.name, '公司');
    await book.save();
    final again = await NodeBook.load();
    expect(again.nodes, hasLength(2));
    expect(again.active?.name, '公司');
  });

  test('reads a country from a node name', () {
    expect(countryCodeOf('韩国'), 'KR');
    expect(countryCodeOf('美国only work'), 'US');
    expect(countryCodeOf('香港 01'), 'HK');
    expect(countryCodeOf('家里的节点'), isNull);
  });

  test('share code can expire', () {
    final past = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final code = encodeShare(
      'https://vpn.example.com',
      'tok',
      'landing',
      '家里',
      '203.0.113.8',
      ShareRule(id: 'sid1', untilMs: past, maxUses: 1),
    );
    final parsed = decodeShare(code!);
    expect(parsed?.shareId, 'sid1');
    expect(parsed?.expired, isTrue);
    expect(parsed?.maxUses, 1);
    final future = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch;
    final live = decodeShare(encodeShare('https://vpn.example.com', 'tok', 'landing', '家里', '', ShareRule(id: 'sid2', untilMs: future))!);
    expect(live?.expired, isFalse);
  });

  test('share code keeps vps ip', () {
    final code = encodeShare('https://vpn.example.com', 'tok', 'landing', '家里', '203.0.113.8');
    final parsed = decodeShare(code!);
    expect(parsed?.name, '家里');
    expect(parsed?.vpsIp, '203.0.113.8');
  });

  test('share pack round trip', () {
    final a = VpnNode(id: '1', name: '家里', endpoint: 'https://a.example.com', token: 't1', exitVia: 'direct');
    final b = VpnNode(id: '2', name: '备用', endpoint: 'https://b.example.com', token: 't2', vpsIp: '203.0.113.8');
    final pack = encodeSharePack([a, b]);
    final parsed = parseShareInput(pack!);
    expect(parsed, hasLength(2));
    expect(parsed.first.name, '家里');
    expect(parsed.last.vpsIp, '203.0.113.8');
    expect(parseShareInput(encodeShare(a.endpoint, a.token, a.exitVia, a.name)!), hasLength(1));
  });

  test('cdn exit is kept in book and share', () {
    final node = VpnNode(
      id: '3',
      name: '橙云',
      endpoint: 'https://vpn.example.com',
      token: 't3',
      exitVia: 'cdn',
      vpsIp: '203.0.113.8',
    );
    expect(node.udp, isTrue);
    expect(normalizeExitVia('cdn'), 'cdn');
    expect(suggestedNodeName(node.endpoint, exitVia: 'cdn'), '橙云 · vpn.example.com');
    expect(exitTitle('cdn'), '橙云 + 服务器');
    expect(supportFlags('cdn', udp: true).last.$2, '支持');
    final parsed = decodeShare(encodeShare(node.endpoint, node.token, node.exitVia, node.name, node.vpsIp)!);
    expect(parsed?.exitVia, 'cdn');
    expect(parsed?.vpsIp, '203.0.113.8');
    final again = VpnNode.fromJson(node.toJson());
    expect(again.exitVia, 'cdn');
  });

  test('subscription replaces only subscribed nodes', () async {
    SharedPreferences.setMockInitialValues({});
    final book = await NodeBook.load();
    book.put(name: '手动', endpoint: 'https://mine.example.com', token: 'm', exitVia: 'direct');
    final manualId = book.active!.id;
    book.applySubscription([
      SharedNode('https://a.example.com', 't1', 'landing', '甲'),
      SharedNode('https://b.example.com', 't2', 'cdn', '乙'),
    ]);
    expect(book.nodes, hasLength(3));
    expect(book.active?.id, manualId);
    book.applySubscription([
      SharedNode('https://b.example.com', 't2b', 'cdn', '乙新'),
    ]);
    expect(book.nodes, hasLength(2));
    expect(book.nodes.any((node) => node.endpoint.contains('a.example')), isFalse);
    expect(book.nodes.any((node) => node.name == '手动'), isTrue);
    expect(book.nodes.firstWhere((node) => node.exitVia == 'cdn').token, 't2b');
    expect(book.nodes.firstWhere((node) => node.exitVia == 'cdn').fromSub, isTrue);
  });
}
