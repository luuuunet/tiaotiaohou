import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'nodes.dart';

class ShareGrant {
  ShareGrant({
    required this.id,
    required this.label,
    required this.createdAt,
    this.untilMs = 0,
    this.maxUses = 0,
    this.usedCount = 0,
    this.disabled = false,
    List<String>? importers,
  }) : importers = importers ?? <String>[];

  final String id;
  final String label;
  final int createdAt;
  final int untilMs;
  final int maxUses;
  int usedCount;
  bool disabled;
  final List<String> importers;

  bool get expired => untilMs > 0 && DateTime.now().millisecondsSinceEpoch > untilMs;

  String get statusLine {
    if (disabled) return '已停用';
    if (expired) return '已过期';
    final parts = <String>[];
    if (untilMs > 0) {
      final left = DateTime.fromMillisecondsSinceEpoch(untilMs).difference(DateTime.now());
      if (left.inDays >= 1) {
        parts.add('还剩 ${left.inDays} 天');
      } else {
        parts.add('还剩 ${left.inHours.clamp(0, 99)} 小时');
      }
    } else {
      parts.add('不过期');
    }
    if (maxUses > 0) {
      parts.add('已用 $usedCount / $maxUses 次');
    } else {
      parts.add('不限次数');
    }
    if (importers.isNotEmpty) {
      parts.add('导入 ${importers.join('、')}');
    }
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'createdAt': createdAt,
        'untilMs': untilMs,
        'maxUses': maxUses,
        'usedCount': usedCount,
        'disabled': disabled,
        'importers': importers,
      };

  static ShareGrant fromJson(Map json) {
    final raw = json['importers'];
    final names = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final name = '$item'.trim();
        if (name.isNotEmpty) names.add(name);
      }
    }
    return ShareGrant(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? ''}',
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : 0,
      untilMs: json['untilMs'] is int ? json['untilMs'] as int : 0,
      maxUses: json['maxUses'] is int ? json['maxUses'] as int : 0,
      usedCount: json['usedCount'] is int ? json['usedCount'] as int : 0,
      disabled: json['disabled'] == true,
      importers: names,
    );
  }
}

class ShareInspect {
  const ShareInspect({required this.nodes, this.expired = const [], this.blocked = false, this.usedUp = false});

  final List<SharedNode> nodes;
  final List<SharedNode> expired;
  final bool blocked;
  final bool usedUp;

  String? get rejectMessage {
    if (blocked) return '这串分享已被停用';
    if (usedUp) return '这串分享次数已经用完';
    if (nodes.isEmpty && expired.isNotEmpty) return '这串分享已经过期';
    if (nodes.isEmpty) return '这串配置无法识别';
    return null;
  }
}

class ShareBook {
  ShareBook(this.grants);

  List<ShareGrant> grants;

  static Future<ShareBook> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final raw = store.getString('share_grants_json') ?? '';
    final grants = <ShareGrant>[];
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final grant = ShareGrant.fromJson(item);
              if (grant.id.isNotEmpty) grants.add(grant);
            }
          }
        }
      } catch (_) {}
    }
    return ShareBook(grants);
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setString('share_grants_json', jsonEncode(grants.map((g) => g.toJson()).toList()));
  }

  ShareGrant? find(String id) {
    if (id.isEmpty) return null;
    for (final grant in grants) {
      if (grant.id == id) return grant;
    }
    return null;
  }

  bool blocked(String id) {
    final grant = find(id);
    return grant != null && (grant.disabled || grant.expired);
  }

  ShareGrant issue({required String label, required int untilMs, required int maxUses}) {
    final grant = ShareGrant(
      id: newNodeId(),
      label: label,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      untilMs: untilMs,
      maxUses: maxUses,
    );
    grants.insert(0, grant);
    if (grants.length > 40) grants = grants.take(40).toList();
    return grant;
  }

  Future<void> disable(String id) async {
    final grant = find(id);
    if (grant == null) return;
    grant.disabled = true;
    await save();
  }

  static String deviceLabel() {
    final user = Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '';
    final host = Platform.localHostname;
    if (user.isEmpty) return host;
    if (host.isEmpty || host.toLowerCase() == user.toLowerCase()) return user;
    return '$user@$host';
  }

  Future<ShareInspect> inspect(String input) async {
    final parsed = parseShareInput(input);
    if (parsed.isEmpty) {
      return const ShareInspect(nodes: []);
    }
    final live = <SharedNode>[];
    final expired = <SharedNode>[];
    var blocked = false;
    var usedUp = false;
    final who = deviceLabel();
    for (final node in parsed) {
      if (node.expired) {
        expired.add(node);
        continue;
      }
      if (node.shareId.isNotEmpty) {
        final grant = find(node.shareId);
        if (grant != null) {
          if (grant.disabled) {
            blocked = true;
            continue;
          }
          if (grant.expired) {
            expired.add(node);
            continue;
          }
          if (grant.maxUses > 0 && grant.usedCount >= grant.maxUses) {
            usedUp = true;
            continue;
          }
          grant.usedCount += 1;
          if (!grant.importers.contains(who)) grant.importers.add(who);
        }
      }
      live.add(node);
    }
    if (live.isNotEmpty) await save();
    return ShareInspect(nodes: live, expired: expired, blocked: blocked && live.isEmpty, usedUp: usedUp && live.isEmpty);
  }
}

ShareRule shareRuleFromGrant(ShareGrant grant) {
  return ShareRule(id: grant.id, untilMs: grant.untilMs, maxUses: grant.maxUses);
}
