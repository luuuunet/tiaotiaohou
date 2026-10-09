import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'flags.dart';
import 'i18n.dart';
import 'look.dart';
import 'node_probe.dart';
import 'share_book.dart';
import 'vps_setup.dart';

String normalizeExitVia(String via) {
  switch (via) {
    case 'direct':
    case 'vps':
    case 'cdn':
      return via;
    default:
      return 'landing';
  }
}

class VpnNode {
  VpnNode({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.token,
    this.exitVia = 'landing',
    this.vpsIp = '',
    this.fromSub = false,
    this.shareId = '',
    this.shareUntilMs = 0,
  });

  final String id;
  String name;
  String endpoint;
  String token;
  String exitVia;
  String vpsIp;
  bool fromSub;
  String shareId;
  int shareUntilMs;

  bool get shareExpired => shareUntilMs > 0 && DateTime.now().millisecondsSinceEpoch > shareUntilMs;

  String get host => Uri.tryParse(endpoint)?.host ?? '';

  bool get ready => endpoint.startsWith('https://') && token.isNotEmpty;

  bool get udp => (vpsIp.isNotEmpty && exitVia != 'direct') || exitVia == 'vps' || exitVia == 'cdn';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'token': token,
        'exitVia': exitVia,
        'vpsIp': vpsIp,
        'fromSub': fromSub,
        if (shareId.isNotEmpty) 'shareId': shareId,
        if (shareUntilMs > 0) 'shareUntilMs': shareUntilMs,
      };

  static VpnNode fromJson(Map json) {
    final via = '${json['exitVia'] ?? json['x'] ?? ''}';
    return VpnNode(
      id: '${json['id'] ?? newNodeId()}',
      name: '${json['name'] ?? json['n'] ?? ''}'.trim(),
      endpoint: '${json['endpoint'] ?? json['e'] ?? ''}'.trim(),
      token: '${json['token'] ?? json['t'] ?? ''}'.trim(),
      exitVia: normalizeExitVia(via),
      vpsIp: publicIpv4('${json['vpsIp'] ?? json['u'] ?? ''}') ?? '',
      fromSub: json['fromSub'] == true,
      shareId: '${json['shareId'] ?? ''}'.trim(),
      shareUntilMs: json['shareUntilMs'] is int ? json['shareUntilMs'] as int : 0,
    );
  }

  VpnNode copy() => VpnNode(
        id: id,
        name: name,
        endpoint: endpoint,
        token: token,
        exitVia: exitVia,
        vpsIp: vpsIp,
        fromSub: fromSub,
        shareId: shareId,
        shareUntilMs: shareUntilMs,
      );
}

String newNodeId() {
  final rand = Random.secure().nextInt(0x7fffffff).toRadixString(16);
  return '${DateTime.now().microsecondsSinceEpoch}-$rand';
}

class NodeBook {
  NodeBook({required this.nodes, required this.activeId});

  List<VpnNode> nodes;
  String activeId;

  VpnNode? get active {
    for (final node in nodes) {
      if (node.id == activeId) return node;
    }
    return nodes.isEmpty ? null : nodes.first;
  }

  static Future<NodeBook> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final raw = store.getString('nodes_json') ?? '';
    final nodes = <VpnNode>[];
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final node = VpnNode.fromJson(item);
              if (node.ready) nodes.add(node);
            }
          }
        }
      } catch (_) {}
    }
    if (nodes.isEmpty) {
      final endpoint = store.getString('endpoint')?.trim() ?? '';
      final token = store.getString('token')?.trim() ?? '';
      if (endpoint.startsWith('https://') && token.isNotEmpty && endpoint != 'https://rsq.lumono.site') {
        final via = store.getString('exit_via') ?? 'landing';
        nodes.add(
          VpnNode(
            id: newNodeId(),
            name: store.getString('node_name')?.trim() ?? '',
            endpoint: endpoint,
            token: token,
            exitVia: normalizeExitVia(via),
            vpsIp: publicIpv4(store.getString('vps_ip') ?? '') ?? '',
          ),
        );
        if (nodes.first.name.isEmpty) {
          nodes.first.name = suggestedNodeName(endpoint, exitVia: nodes.first.exitVia);
        }
      }
    }
    var activeId = store.getString('active_node_id') ?? '';
    if (nodes.isEmpty) {
      activeId = '';
    } else if (!nodes.any((node) => node.id == activeId)) {
      activeId = nodes.first.id;
    }
    return NodeBook(nodes: nodes, activeId: activeId);
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setString('nodes_json', jsonEncode(nodes.map((node) => node.toJson()).toList()));
    await store.setString('active_node_id', activeId);
    final current = active;
    await store.setString('endpoint', current?.endpoint ?? '');
    await store.setString('token', current?.token ?? '');
    await store.setString('node_name', current?.name ?? '');
    await store.setString('exit_via', current?.exitVia ?? 'landing');
    await store.setString('vps_ip', current?.vpsIp ?? '');
  }

  VpnNode put({
    String? id,
    required String name,
    required String endpoint,
    required String token,
    required String exitVia,
    String vpsIp = '',
    bool addIfMissing = true,
    String shareId = '',
    int shareUntilMs = 0,
  }) {
    VpnNode? found;
    if (id != null) {
      for (final node in nodes) {
        if (node.id == id) found = node;
      }
    }
    found ??= () {
      for (final node in nodes) {
        if (node.endpoint == endpoint && node.exitVia == exitVia) return node;
      }
      return null;
    }();
    if (found != null) {
      found.name = name.trim().isEmpty ? found.name : name.trim();
      found.endpoint = endpoint;
      found.token = token;
      found.exitVia = exitVia;
      found.vpsIp = publicIpv4(vpsIp) ?? '';
      if (shareId.isNotEmpty) found.shareId = shareId;
      if (shareUntilMs > 0) found.shareUntilMs = shareUntilMs;
      activeId = found.id;
      return found;
    }
    if (!addIfMissing) {
      throw StateError('node missing');
    }
    final node = VpnNode(
      id: id ?? newNodeId(),
      name: name.trim().isEmpty ? suggestedNodeName(endpoint, exitVia: exitVia) : name.trim(),
      endpoint: endpoint,
      token: token,
      exitVia: exitVia,
      vpsIp: publicIpv4(vpsIp) ?? '',
      shareId: shareId,
      shareUntilMs: shareUntilMs,
    );
    nodes.add(node);
    activeId = node.id;
    return node;
  }

  void select(String id) {
    if (nodes.any((node) => node.id == id)) activeId = id;
  }

  void remove(String id) {
    nodes.removeWhere((node) => node.id == id);
    if (activeId == id) activeId = nodes.isEmpty ? '' : nodes.first.id;
  }

  /// 用订阅内容替换上次来自订阅的节点，手动添加的保留。
  int applySubscription(List<SharedNode> incoming) {
    String key(String endpoint, String via) => '$endpoint|$via';
    final wanted = <String, SharedNode>{};
    for (final item in incoming) {
      if (!item.endpoint.startsWith('https://') || item.token.isEmpty) continue;
      wanted[key(item.endpoint, item.exitVia)] = item;
    }
    nodes.removeWhere((node) => node.fromSub && !wanted.containsKey(key(node.endpoint, node.exitVia)));
    for (final item in wanted.values) {
      VpnNode? found;
      for (final node in nodes) {
        if (node.endpoint == item.endpoint && node.exitVia == item.exitVia) {
          found = node;
          break;
        }
      }
      if (found != null) {
        if (item.name.trim().isNotEmpty && (found.fromSub || found.name.trim().isEmpty)) {
          found.name = item.name.trim();
        }
        found.token = item.token;
        found.vpsIp = item.vpsIp;
        found.fromSub = true;
        if (item.shareId.isNotEmpty) found.shareId = item.shareId;
        if (item.untilMs > 0) found.shareUntilMs = item.untilMs;
      } else {
        nodes.add(VpnNode(
          id: newNodeId(),
          name: item.name.trim().isEmpty ? suggestedNodeName(item.endpoint, exitVia: item.exitVia) : item.name.trim(),
          endpoint: item.endpoint,
          token: item.token,
          exitVia: item.exitVia,
          vpsIp: item.vpsIp,
          fromSub: true,
          shareId: item.shareId,
          shareUntilMs: item.untilMs,
        ));
      }
    }
    if (nodes.isEmpty) {
      activeId = '';
    } else if (!nodes.any((node) => node.id == activeId)) {
      activeId = nodes.first.id;
    }
    return wanted.length;
  }
}

class NodeBookView extends StatefulWidget {
  const NodeBookView({super.key, this.onChanged, this.onConnect, this.running = false, this.connecting = false});

  final Future<void> Function()? onChanged;
  final Future<void> Function(VpnNode node)? onConnect;
  final bool running;
  final bool connecting;

  @override
  State<NodeBookView> createState() => _NodeBookViewState();
}

class _NodeBookViewState extends State<NodeBookView> {
  NodeBook? _book;
  final _query = TextEditingController();
  final _picked = <String>{};
  final _probes = <String, NodeProbe>{};
  final _testing = <String>{};
  var _busyTest = false;
  List<ShareGrant> _grants = const [];

  @override
  void initState() {
    super.initState();
    _reload().then((_) => _retestActive());
  }

  @override
  void didUpdateWidget(NodeBookView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.running && widget.running) {
      _retestActive();
    }
  }

  void _retestActive() {
    if (!widget.running) return;
    final node = _book?.active;
    if (node == null) return;
    setState(() => _probes.remove(node.id));
    unawaited(_test(node));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final book = await NodeBook.load();
    final shares = await ShareBook.load();
    if (!mounted) return;
    setState(() {
      _book = book;
      _grants = shares.grants;
    });
  }

  Future<void> _commit(NodeBook book) async {
    await book.save();
    if (widget.onChanged != null) await widget.onChanged!();
    if (!mounted) return;
    setState(() => _book = book);
  }

  void _toast(String text) {
    if (!mounted) return;
    showTicketSnack(context, text);
  }

  List<VpnNode> _visible(NodeBook book) {
    final q = _query.text.trim().toLowerCase();
    return book.nodes.where((node) {
      if (q.isEmpty) return true;
      return node.name.toLowerCase().contains(q) || node.host.toLowerCase().contains(q) || node.endpoint.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _test(VpnNode node) async {
    setState(() => _testing.add(node.id));
    final result = await probeNode(node);
    if (!mounted) return;
    setState(() {
      _testing.remove(node.id);
      _probes[node.id] = result;
    });
  }

  Future<void> _testAll() async {
    final book = _book;
    if (book == null || book.nodes.isEmpty) {
      _toast('还没有节点');
      return;
    }
    setState(() => _busyTest = true);
    for (final node in List<VpnNode>.from(book.nodes)) {
      if (!mounted) return;
      await _test(node);
    }
    if (!mounted) return;
    setState(() => _busyTest = false);
    final up = _probes.values.where((p) => p.ok).length;
    _toast('测完了：可用 $up / ${book.nodes.length}');
  }

  Future<void> _shareBatch() async {
    final book = _book;
    if (book == null || book.nodes.isEmpty) {
      _toast('还没有节点');
      return;
    }
    var targets = book.nodes.where((node) => _picked.contains(node.id)).toList();
    if (targets.isEmpty) {
      final choice = await showTicketDialog<String>(
        context,
        (context) => TicketSheet(
          kicker: 'SHARE',
          title: '批量分享',
          child: const Text('没有勾选时，可以分享全部，或只分享测过可用的。', style: TextStyle(color: kMute, height: 1.45, fontSize: 14)),
          actions: [
            GhostButton(label: '取消', onTap: () => Navigator.pop(context)),
            GhostButton(label: '仅可用', onTap: () => Navigator.pop(context, 'up')),
            FilledButton(onPressed: () => Navigator.pop(context, 'all'), child: const Text('全部')),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'up') {
        targets = book.nodes.where((node) => _probes[node.id]?.ok == true).toList();
        if (targets.isEmpty) {
          _toast('还没有测到可用节点，先点「测试全部」');
          return;
        }
      } else {
        targets = List<VpnNode>.from(book.nodes);
      }
    }
    final rule = await _pickShareRule(targets.first.name.isEmpty ? targets.first.host : targets.first.name, count: targets.length);
    if (rule == null) return;
    final code = encodeSharePack(targets, rule);
    if (code == null) {
      _toast('没有可分享的节点');
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    _toast('已复制 ${targets.length} 条节点');
  }

  Future<void> _importBatch() async {
    final text = await showTicketDialog<String>(
      context,
      (context) => const _ImportDialog(),
    );
    if (text == null) return;
    final ledger = await ShareBook.load();
    final inspected = await ledger.inspect(text);
    final reject = inspected.rejectMessage;
    if (reject != null) {
      _toast(reject);
      return;
    }
    final book = _book ?? await NodeBook.load();
    for (final node in inspected.nodes) {
      book.put(
        name: node.name,
        endpoint: node.endpoint,
        token: node.token,
        exitVia: node.exitVia,
        vpsIp: node.vpsIp,
        shareId: node.shareId,
        shareUntilMs: node.untilMs,
      );
    }
    await _commit(book);
    _toast(inspected.nodes.length == 1 ? '已导入 1 条' : '已导入 ${inspected.nodes.length} 条');
  }

  Future<void> _edit({VpnNode? existing}) async {
    final result = await showTicketDialog<VpnNode>(
      context,
      (context) => _NodeEditor(existing: existing),
    );
    if (result == null || !result.ready) return;
    final book = _book ?? await NodeBook.load();
    book.put(
      id: existing?.id,
      name: result.name,
      endpoint: result.endpoint,
      token: result.token,
      exitVia: result.exitVia,
      vpsIp: result.vpsIp,
    );
    await _commit(book);
    _toast(existing == null ? '已添加节点' : '已保存节点');
  }

  Future<void> _use(VpnNode node) async {
    final book = _book;
    if (book == null) return;
    book.select(node.id);
    await _commit(book);
    _toast('已选用「${node.name.isEmpty ? node.host : node.name}」');
  }

  Future<ShareRule?> _pickShareRule(String label, {int count = 1}) async {
    final picked = await showTicketDialog<_SharePick>(
      context,
      (context) => _ShareOptionsSheet(label: label, count: count),
    );
    if (picked == null) return null;
    final ledger = await ShareBook.load();
    final grant = ledger.issue(label: count > 1 ? '$label 等$count条' : label, untilMs: picked.untilMs, maxUses: picked.maxUses);
    await ledger.save();
    if (mounted) setState(() {});
    return shareRuleFromGrant(grant);
  }

  Future<void> _share(VpnNode node) async {
    final rule = await _pickShareRule(node.name.isEmpty ? node.host : node.name);
    if (rule == null) return;
    final code = encodeShare(node.endpoint, node.token, node.exitVia, node.name, node.vpsIp, rule);
    if (code == null) {
      _toast('这条节点还不完整，先编辑填好');
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    _toast('节点配置已复制');
  }

  Future<void> _delete(VpnNode node) async {
    final ok = await showTicketDialog<bool>(
      context,
      (context) => TicketSheet(
        kicker: 'DEL',
        title: '删除这个节点？',
        child: Text(node.name.isEmpty ? node.host : node.name, style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 16)),
        actions: [
          GhostButton(label: '取消', onTap: () => Navigator.pop(context, false)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final book = _book;
    if (book == null) return;
    book.remove(node.id);
    await _commit(book);
    _toast('已删除');
  }

  Future<void> _deleteDown() async {
    final book = _book;
    if (book == null) return;
    final targets = book.nodes.where((node) => _probes[node.id]?.ok == false).toList();
    if (targets.isEmpty) {
      _toast('还没有测出不可用节点，先点「测试」');
      return;
    }
    final ok = await showTicketDialog<bool>(
      context,
      (context) => TicketSheet(
        kicker: 'DEL',
        title: '删除 ${targets.length} 条不可用节点？',
        child: const Text('只删这次测出来不可用的。没测过的和正常的会留下。', style: TextStyle(color: kMute, height: 1.45, fontSize: 14)),
        actions: [
          GhostButton(label: '取消', onTap: () => Navigator.pop(context, false)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    for (final node in targets) {
      book.remove(node.id);
      _probes.remove(node.id);
      _picked.remove(node.id);
    }
    await _commit(book);
    _toast('已删除 ${targets.length} 条不可用节点');
  }

  Future<void> _deletePicked() async {
    final book = _book;
    if (book == null) return;
    final targets = book.nodes.where((node) => _picked.contains(node.id)).toList();
    if (targets.isEmpty) {
      _toast('先勾选要删除的节点');
      return;
    }
    final ok = await showTicketDialog<bool>(
      context,
      (context) => TicketSheet(
        kicker: 'DEL',
        title: '删除勾选的 ${targets.length} 条？',
        child: Text(
          targets.map((node) => node.name.isEmpty ? node.host : node.name).join('、'),
          style: const TextStyle(color: kInk, fontWeight: FontWeight.w700, height: 1.4),
        ),
        actions: [
          GhostButton(label: '取消', onTap: () => Navigator.pop(context, false)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    for (final node in targets) {
      book.remove(node.id);
      _probes.remove(node.id);
      _picked.remove(node.id);
    }
    await _commit(book);
    _toast('已删除 ${targets.length} 条');
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    if (book == null) {
      return const Center(child: CircularProgressIndicator(color: kInk));
    }
    final shown = _visible(book);
    final down = _probes.values.where((p) => !p.ok).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                cursorColor: kInk,
                style: const TextStyle(color: kInk, fontWeight: FontWeight.w600, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '搜索名称或域名',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _importBatch, child: Text(tx('导入', 'Import'))),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => _edit(), child: Text(tx('添加', 'Add'))),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            InkChip(label: _busyTest ? tx('测试中', 'Testing') : tx('测试', 'Test'), onTap: _busyTest ? null : _testAll),
            InkChip(label: tx('分享', 'Share'), onTap: _shareBatch),
            InkChip(label: down == 0 ? '删除不可用' : '删除不可用 $down', onTap: _busyTest ? null : _deleteDown),
            InkChip(label: _picked.isEmpty ? '删除勾选' : '删除勾选 ${_picked.length}', onTap: _deletePicked),
          ],
        ),
        if (_grants.isNotEmpty) ...[
          const SizedBox(height: 10),
          _grantStrip(),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    book.nodes.isEmpty ? '还没有节点。去「搭建」自动生成，或点「添加」。' : '没有匹配的节点',
                    style: const TextStyle(color: kMute, height: 1.45),
                  ),
                )
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final node = shown[index];
                    final on = node.id == book.activeId;
                    final title = node.name.isEmpty ? '未命名' : node.name;
                    final probing = _testing.contains(node.id);
                    final probe = _probes[node.id];
                    final picked = _picked.contains(node.id);
                    return Material(
                      color: on ? const Color(0xFFF4FBE8) : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: kInk, width: on ? 2 : 1.1),
                      ),
                      child: InkWell(
                        onTap: () => _use(node),
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          height: 76,
                          child: Row(
                            children: [
                              Checkbox(
                                value: picked,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                onChanged: (value) => setState(() {
                                  if (value == true) {
                                    _picked.add(node.id);
                                  } else {
                                    _picked.remove(node.id);
                                  }
                                }),
                                side: const BorderSide(color: kInk, width: 1.4),
                                activeColor: kInk,
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (countryCodeOf(title) != null) ...[
                                          FlagMark(countryCodeOf(title)!, height: 14),
                                          const SizedBox(width: 6),
                                        ],
                                        if (on) ...[
                                          const YouBadge('用'),
                                          const SizedBox(width: 6),
                                        ],
                                        Flexible(
                                          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: kInk)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${node.host.isEmpty ? node.endpoint : node.host}  ·  ${exitTitle(node.exitVia)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: kMute, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              _connectButton(node, on),
                              const SizedBox(width: 4),
                              _availBadge(probing, probe),
                              TicketMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'test':
                                      _test(node);
                                    case 'edit':
                                      _edit(existing: node);
                                    case 'share':
                                      _share(node);
                                    case 'delete':
                                      _delete(node);
                                  }
                                },
                                items: [
                                  _menuItem('test', '测试'),
                                  _menuItem('edit', '编辑'),
                                  _menuItem('share', '分享'),
                                  _menuItem('delete', '删除', color: const Color(0xFFB42318)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _connectButton(VpnNode node, bool selected) {
    final connecting = widget.connecting && selected;
    final live = widget.running && selected && !connecting;
    return FilledButton.icon(
      onPressed: (live || connecting) ? null : () => widget.onConnect?.call(node),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 32),
        disabledBackgroundColor: kMint,
        disabledForegroundColor: kInk,
      ),
      icon: connecting ? const ConnectMark(color: kInk, size: 16) : AppIcon('power.svg', size: 14, color: live ? kInk : Colors.white),
      label: Text(connecting ? tx('连接中', 'Connecting') : (live ? tx('已连接', 'On') : tx('连接', 'Connect'))),
    );
  }

  Widget _availBadge(bool probing, NodeProbe? probe) {
    if (probing) {
      return const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kInk));
    }
    final on = probe?.ok == true;
    final bad = probe != null && !probe.ok;
    final text = probe == null ? tx('未测', 'New') : (on ? tx('可用', 'Up') : probe.detail);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: on ? kMint : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bad ? const Color(0xFFB42318) : kInk, width: 1.1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (on) ...[
            const Icon(Icons.check_rounded, size: 14, color: kInk),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: bad ? const Color(0xFFB42318) : kInk),
          ),
        ],
      ),
    );
  }

  Widget _grantStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('发出去的分享', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 6),
        ..._grants.take(6).map((grant) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${grant.label}  ·  ${grant.statusLine}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMute, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (!grant.disabled)
                  InkChip(label: '停用', onTap: () => _disableGrant(grant)),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _disableGrant(ShareGrant grant) async {
    final ledger = await ShareBook.load();
    await ledger.disable(grant.id);
    if (!mounted) return;
    setState(() => _grants = ledger.grants);
    _toast('已停用这次分享');
  }

  PopupMenuItem<String> _menuItem(String value, String label, {Color color = kInk}) {
    return PopupMenuItem(
      value: value,
      height: 40,
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13)),
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TicketSheet(
      kicker: 'IN',
      title: '批量导入',
      child: TicketField(
        label: '配置',
        hint: '粘贴 tiaotiaohou1 或 tiaotiaohou2 配置，一次可多条',
        controller: _text,
        minLines: 6,
        maxLines: 10,
      ),
      actions: [
        GhostButton(label: '取消', onTap: () => Navigator.pop(context)),
        FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('导入')),
      ],
    );
  }
}

class _NodeEditor extends StatefulWidget {
  const _NodeEditor({this.existing});
  final VpnNode? existing;

  @override
  State<_NodeEditor> createState() => _NodeEditorState();
}

class _NodeEditorState extends State<_NodeEditor> {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _vps;
  late String _exitVia;
  var _obscure = true;

  @override
  void initState() {
    super.initState();
    final node = widget.existing;
    _name = TextEditingController(text: node?.name ?? '');
    _endpoint = TextEditingController(text: node?.endpoint ?? '');
    _token = TextEditingController(text: node?.token ?? '');
    _vps = TextEditingController(text: node?.vpsIp ?? '');
    _exitVia = node?.exitVia ?? 'landing';
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _token.dispose();
    _vps.dispose();
    super.dispose();
  }

  void _ok() {
    final endpoint = _endpoint.text.trim();
    final token = _token.text.trim();
    if (!endpoint.startsWith('https://') || token.isEmpty) {
      showTicketSnack(context, '节点要 https:// 开头，连接令牌也要填');
      return;
    }
    Navigator.pop(
      context,
      VpnNode(
        id: widget.existing?.id ?? newNodeId(),
        name: _name.text.trim(),
        endpoint: endpoint,
        token: token,
        exitVia: _exitVia,
        vpsIp: publicIpv4(_vps.text) ?? _vps.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TicketSheet(
      kicker: widget.existing == null ? 'NEW' : 'EDIT',
      title: widget.existing == null ? '添加节点' : '编辑节点',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TicketField(label: '名称', hint: '例如 家里、公司、备用线路', controller: _name),
          const SizedBox(height: 12),
          TicketField(label: '节点地址', hint: 'https://vpn.example.com', controller: _endpoint),
          const SizedBox(height: 12),
          TicketField(
            label: '连接令牌',
            controller: _token,
            obscure: _obscure,
            suffix: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: AppIcon(_obscure ? 'eye-off.svg' : 'eye.svg', color: kMute),
            ),
          ),
          const SizedBox(height: 14),
          const Text('出口', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InkChip(label: 'Cloudflare 直连', selected: _exitVia == 'direct', onTap: () => setState(() => _exitVia = 'direct')),
              InkChip(label: 'Worker + 落地', selected: _exitVia == 'landing', onTap: () => setState(() => _exitVia = 'landing')),
              InkChip(label: '橙云 + 服务器', selected: _exitVia == 'cdn', onTap: () => setState(() => _exitVia = 'cdn')),
              InkChip(label: '直连 VPS', selected: _exitVia == 'vps', onTap: () => setState(() => _exitVia = 'vps')),
            ],
          ),
          const SizedBox(height: 12),
          TicketField(label: '落地 IP（游戏 UDP，可空）', hint: '例如 66.94.122.53', controller: _vps),
        ],
      ),
      actions: [
        GhostButton(label: '取消', onTap: () => Navigator.pop(context)),
        FilledButton(onPressed: _ok, child: const Text('保存')),
      ],
    );
  }
}

class ShareRule {
  const ShareRule({this.id = '', this.untilMs = 0, this.maxUses = 0});
  final String id;
  final int untilMs;
  final int maxUses;
}

class SharedNode {
  const SharedNode(
    this.endpoint,
    this.token, [
    this.exitVia = 'landing',
    this.name = '',
    this.vpsIp = '',
    this.shareId = '',
    this.untilMs = 0,
    this.maxUses = 0,
  ]);
  final String endpoint;
  final String token;
  final String exitVia;
  final String name;
  final String vpsIp;
  final String shareId;
  final int untilMs;
  final int maxUses;

  bool get expired => untilMs > 0 && DateTime.now().millisecondsSinceEpoch > untilMs;
}

String suggestedNodeName(String endpoint, {String exitVia = 'landing'}) {
  final host = Uri.tryParse(endpoint)?.host ?? '';
  switch (exitVia) {
    case 'vps':
      return host.isEmpty ? '服务器节点' : '服务器 · $host';
    case 'cdn':
      return host.isEmpty ? '橙云节点' : '橙云 · $host';
    case 'direct':
      return host.isEmpty ? 'Cloudflare 节点' : 'Cloudflare · $host';
    default:
      return host.isEmpty ? '落地节点' : '落地 · $host';
  }
}

Map<String, dynamic> _shareFields(String endpoint, String token, String exitVia, String name, String vpsIp, [ShareRule? rule]) {
  return {
    'v': 1,
    'e': endpoint,
    't': token,
    'x': exitVia,
    if (name.trim().isNotEmpty) 'n': name.trim(),
    if (vpsIp.trim().isNotEmpty) 'u': vpsIp.trim(),
    if (rule != null && rule.id.isNotEmpty) 's': rule.id,
    if (rule != null && rule.untilMs > 0) 'exp': rule.untilMs,
    if (rule != null && rule.maxUses > 0) 'm': rule.maxUses,
  };
}

SharedNode? _nodeFromShareMap(Map json) {
  final endpoint = '${json['e'] ?? ''}'.trim();
  final token = '${json['t'] ?? ''}'.trim();
  final via = '${json['x'] ?? ''}';
  final name = '${json['n'] ?? ''}'.trim();
  final vpsIp = publicIpv4('${json['u'] ?? ''}') ?? '';
  if (!endpoint.startsWith('https://') || token.isEmpty) return null;
  final until = json['exp'];
  final max = json['m'];
  return SharedNode(
    endpoint,
    token,
    normalizeExitVia(via),
    name,
    vpsIp,
    '${json['s'] ?? ''}'.trim(),
    until is int ? until : 0,
    max is int ? max : 0,
  );
}

String? encodeShare(String endpoint, String token, [String exitVia = 'landing', String name = '', String vpsIp = '', ShareRule? rule]) {
  if (!endpoint.startsWith('https://') || token.isEmpty) return null;
  final raw = jsonEncode(_shareFields(endpoint, token, exitVia, name, vpsIp, rule));
  return 'tiaotiaohou1.${base64Url.encode(utf8.encode(raw))}';
}

String _stripSharePrefix(String input) {
  final text = input.trim();
  for (final prefix in ['tiaotiaohou1.', 'crush1.']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

SharedNode? decodeShare(String input) {
  final text = _stripSharePrefix(input);
  try {
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(text)));
    final json = jsonDecode(decoded);
    if (json is! Map) return null;
    return _nodeFromShareMap(json);
  } catch (_) {
    return null;
  }
}

String? encodeSharePack(Iterable<VpnNode> nodes, [ShareRule? rule]) {
  final items = <Map<String, dynamic>>[];
  for (final node in nodes) {
    if (!node.ready) continue;
    items.add(_shareFields(node.endpoint, node.token, node.exitVia, node.name, node.vpsIp, rule));
  }
  if (items.isEmpty) return null;
  final raw = jsonEncode({
    'v': 2,
    'n': items,
    if (rule != null && rule.id.isNotEmpty) 's': rule.id,
    if (rule != null && rule.untilMs > 0) 'exp': rule.untilMs,
    if (rule != null && rule.maxUses > 0) 'm': rule.maxUses,
  });
  return 'tiaotiaohou2.${base64Url.encode(utf8.encode(raw))}';
}

List<SharedNode> parseShareInput(String input) {
  final text = input.trim();
  if (text.isEmpty) return const [];
  if (text.startsWith('tiaotiaohou2.') || text.startsWith('crush2.')) {
    final payload = text.startsWith('tiaotiaohou2.') ? text.substring('tiaotiaohou2.'.length) : text.substring('crush2.'.length);
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
      final json = jsonDecode(decoded);
      if (json is! Map) return const [];
      final list = json['n'];
      if (list is! List) return const [];
      final packId = '${json['s'] ?? ''}'.trim();
      final packUntil = json['exp'] is int ? json['exp'] as int : 0;
      final packMax = json['m'] is int ? json['m'] as int : 0;
      final out = <SharedNode>[];
      for (final item in list) {
        if (item is Map) {
          final node = _nodeFromShareMap(item);
          if (node == null) continue;
          if (node.shareId.isEmpty && packId.isNotEmpty) {
            out.add(SharedNode(node.endpoint, node.token, node.exitVia, node.name, node.vpsIp, packId, node.untilMs > 0 ? node.untilMs : packUntil, node.maxUses > 0 ? node.maxUses : packMax));
          } else {
            out.add(node);
          }
        } else if (item is String) {
          final one = decodeShare(item);
          if (one != null) out.add(one);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
  if (text.startsWith('tiaotiaohou1.') || text.startsWith('crush1.')) {
    final one = decodeShare(text);
    return one == null ? const [] : [one];
  }
  final out = <SharedNode>[];
  for (final part in text.split(RegExp(r'\s+'))) {
    if (part.isEmpty) continue;
    final one = decodeShare(part);
    if (one != null) out.add(one);
  }
  return out;
}

String exitTitle(String via) {
  switch (via) {
    case 'direct':
      return tx('Cloudflare 直连', 'Cloudflare direct');
    case 'vps':
      return tx('直连 VPS', 'Direct VPS');
    case 'cdn':
      return tx('橙云 + 服务器', 'Orange cloud + server');
    default:
      return tx('Worker + 落地', 'Worker + landing');
  }
}

String exitHint(String via) {
  switch (via) {
    case 'direct':
      return '没有自己的服务器。普通网站可以打开。还有网站进不去时，到「本机」打开「打开打不开的网站」。游戏过不去。';
    case 'vps':
      return '客户端直接连你的 VPS，不经过 Cloudflare。网站用落地 IP，游戏走 UDP 8444。';
    case 'cdn':
      return '域名走 Cloudflare 橙云，回源到你的 VPS。不计 Worker，客户端优先 HTTP/3。游戏走 UDP 8444。';
    default:
      return '先连 Cloudflare Worker，再从 VPS 访问网站。填了落地 IP 时，游戏走 UDP 8444。';
  }
}

List<(String, String, bool)> supportFlags(String via, {bool udp = false}) {
  if (via.isEmpty) {
    return const [
      ('网页', '—', false),
      ('橙云网站', '—', false),
      ('游戏 UDP', '—', false),
    ];
  }
  final web = via == 'direct' ? ('网页', '部分支持', true) : ('网页', '支持', true);
  final orange = via == 'direct' ? ('橙云网站', '本机可开', true) : ('橙云网站', '支持', true);
  final game = (udp || via == 'vps' || via == 'cdn') ? ('游戏 UDP', '支持', true) : ('游戏 UDP', '不支持', false);
  return [web, orange, game];
}

String _flagLabel(String name, String state, bool on) {
  const enName = {'网页': 'Web', '橙云网站': 'Orange cloud', '游戏 UDP': 'Game UDP'};
  const enState = {'支持': 'Yes', '部分支持': 'Partial', '本机可开': 'Optional', '不支持': 'No', '—': '—'};
  final title = tx(name, enName[name] ?? name);
  if (on && (state == '支持' || state == '本机可开' || state == '部分支持')) return title;
  return '$title  ${tx(state, enState[state] ?? state)}';
}

String _supportIcon(String label) {
  if (label.startsWith('游戏')) return 'server.svg';
  if (label.startsWith('橙云')) return 'cloud.svg';
  return 'globe.svg';
}

class SupportStrip extends StatelessWidget {
  const SupportStrip({super.key, required this.exitVia, this.udp = false});

  final String exitVia;
  final bool udp;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in supportFlags(exitVia, udp: udp))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: item.$3 ? kMint : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kInk, width: 1.1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(_supportIcon(item.$1), size: 15),
                const SizedBox(width: 6),
                Text(
                  _flagLabel(item.$1, item.$2, item.$3),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: kInk),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SharePick {
  const _SharePick(this.untilMs, this.maxUses);
  final int untilMs;
  final int maxUses;
}

class _ShareOptionsSheet extends StatefulWidget {
  const _ShareOptionsSheet({required this.label, this.count = 1});
  final String label;
  final int count;

  @override
  State<_ShareOptionsSheet> createState() => _ShareOptionsSheetState();
}

class _ShareOptionsSheetState extends State<_ShareOptionsSheet> {
  var _days = 7;
  var _uses = 0;

  @override
  Widget build(BuildContext context) {
    return TicketSheet(
      kicker: 'SHARE',
      title: widget.count > 1 ? '分享 ${widget.count} 条节点' : '分享节点',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          const Text('可以设过期时间和次数。停用后，本机再导入这串配置会拒绝。', style: TextStyle(color: kMute, height: 1.45, fontSize: 13)),
          const SizedBox(height: 14),
          const Text('有效期', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in [(1, '1 天'), (7, '7 天'), (30, '30 天'), (0, '不过期')])
                InkChip(label: item.$2, selected: _days == item.$1, onTap: () => setState(() => _days = item.$1)),
            ],
          ),
          const SizedBox(height: 14),
          const Text('使用次数', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in [(1, '1 次'), (5, '5 次'), (0, '不限')])
                InkChip(label: item.$2, selected: _uses == item.$1, onTap: () => setState(() => _uses = item.$1)),
            ],
          ),
        ],
      ),
      actions: [
        GhostButton(label: '取消', onTap: () => Navigator.pop(context)),
        FilledButton(
          onPressed: () {
            final until = _days == 0 ? 0 : DateTime.now().add(Duration(days: _days)).millisecondsSinceEpoch;
            Navigator.pop(context, _SharePick(until, _uses));
          },
          child: const Text('复制'),
        ),
      ],
    );
  }
}
