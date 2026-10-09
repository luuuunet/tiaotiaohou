import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'nodes.dart';

class SubscriptionException implements Exception {
  SubscriptionException(this.message);
  final String message;
  @override
  String toString() => message;
}

const subRefreshEvery = Duration(hours: 1);

Future<String> updateSubscription(String url, {int tries = 3}) async {
  final text = url.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
    throw SubscriptionException('订阅地址要是 http 或 https');
  }
  Object? last;
  for (var i = 0; i < tries; i++) {
    try {
      final body = await _fetch(uri);
      final nodes = parseShareInput(body);
      if (nodes.isEmpty) {
        throw SubscriptionException('订阅里没有识别到节点');
      }
      final book = await NodeBook.load();
      final count = book.applySubscription(nodes);
      await book.save();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sub_url', text);
      await prefs.setInt('sub_fetched_at', DateTime.now().millisecondsSinceEpoch);
      await prefs.remove('sub_last_error');
      return '已更新 $count 条订阅节点';
    } on SubscriptionException catch (err) {
      last = err;
    } catch (err) {
      last = err;
    }
    if (i < tries - 1) {
      await Future<void>.delayed(Duration(seconds: 2 * (i + 1)));
    }
  }
  final message = last is SubscriptionException ? last.message : '订阅更新失败';
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('sub_url', text);
  await prefs.setString('sub_last_error', message);
  throw SubscriptionException(message);
}

Future<bool> subscriptionIsStale() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('sub_url')?.trim() ?? '';
  if (url.isEmpty) return false;
  final fetched = prefs.getInt('sub_fetched_at') ?? 0;
  return DateTime.now().millisecondsSinceEpoch - fetched >= subRefreshEvery.inMilliseconds;
}

Future<String> _fetch(Uri uri) async {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 12));
    request.headers.set(HttpHeaders.userAgentHeader, 'tiaotiaohou');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SubscriptionException('订阅返回 ${response.statusCode}');
    }
    if (body.length > 512 * 1024) {
      throw SubscriptionException('订阅内容太大');
    }
    return body;
  } on SubscriptionException {
    rethrow;
  } on SocketException {
    throw SubscriptionException('订阅地址连不上');
  } on HttpException {
    throw SubscriptionException('订阅地址连不上');
  } catch (_) {
    throw SubscriptionException('订阅更新失败');
  } finally {
    client.close(force: true);
  }
}
