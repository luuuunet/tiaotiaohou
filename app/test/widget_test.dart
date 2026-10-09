import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/look.dart';
import 'package:rsq/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the connect screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const RsqApp());
    expect(find.text('跳跳猴'), findsOneWidget);
    expect(find.text('一只会跳跳的猴子'), findsOneWidget);
    expect(find.text('特别感谢 Cloudflare 的支持'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('还没有节点，请先在设置里添加'), findsOneWidget);
    expect(find.text('网页  —'), findsOneWidget);
    expect(supportFlags('landing', udp: true).last.$2, '支持');
    expect(supportFlags('landing').last.$2, '不支持');
    expect(find.byType(AppIcon), findsWidgets);
    await tester.tap(find.text('节点').first);
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('导入'), findsWidgets);
  });

  test('share code round trip', () {
    const endpoint = 'https://rsq.example.com';
    const token = 'abc';
    final code = encodeShare(endpoint, token);
    final parsed = decodeShare(code!);
    expect(parsed?.endpoint, endpoint);
    expect(parsed?.token, token);
    expect(parsed?.exitVia, 'landing');
    final named = encodeShare(endpoint, token, 'landing', '家里');
    expect(decodeShare(named!)?.name, '家里');
    final vps = encodeShare(endpoint, token, 'vps');
    expect(decodeShare(vps!)?.exitVia, 'vps');
    final cdn = encodeShare(endpoint, token, 'cdn');
    expect(decodeShare(cdn!)?.exitVia, 'cdn');
    expect(decodeShare('not-a-code'), isNull);
  });

  testWidgets('setup has orange-cloud tab', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const RsqApp());
    await tester.tap(find.text('搭建').first);
    await tester.pumpAndSettle();
    expect(find.text('橙云 + 服务器'), findsWidgets);
    expect(find.text('Worker + 服务器'), findsWidgets);
    expect(find.text('只用 Cloudflare'), findsWidgets);
  });
}
