import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'autostart.dart';
import 'bypass.dart';
import 'cf_best_ip.dart';
import 'cloudflare_setup.dart';
import 'core_api.dart';
import 'desktop_host.dart';
import 'diagnostics.dart';
import 'flags.dart';
import 'i18n.dart';
import 'look.dart';
import 'node_probe.dart';
import 'nodes.dart';
import 'share_book.dart';
import 'subscription.dart';
import 'system_proxy.dart';
import 'vps_setup.dart';
import 'window_chrome.dart';

export 'bypass.dart' show normalizeBypassHost, hostBypasses;
export 'nodes.dart' show encodeShare, decodeShare, encodeSharePack, parseShareInput, supportFlags, NodeBook, VpnNode, ShareRule;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLang.I.load();
  runApp(const RsqApp());
}

class RsqApp extends StatelessWidget {
  const RsqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '跳跳猴',
      debugShowCheckedModeBanner: false,
      theme: ticketTheme(),
      scrollBehavior: const TicketScrollBehavior(),
      home: const WindowShell(child: HomePage()),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _channel = MethodChannel('dev.rsq/host');

  String _endpoint = '';
  String _token = '';
  String _nodeName = '';
  String _activeId = '';
  var _nodes = <VpnNode>[];
  int _socks = 1080;
  int _http = 8080;
  var _preferH3 = true;
  var _cfBestOn = true;
  var _cfBestIp = '';
  var _cfBestMs = 0;
  var _cfBestColo = '';
  var _cfBestHost = '';
  var _cfBestAt = 0;
  var _cfPicking = false;
  var _fetchEnabled = false;
  var _exitVia = 'landing';
  var _vpsIp = '';
  var _systemProxy = !Platform.isAndroid;
  var _bypass = <String>[];
  var _autoConnect = false;
  var _autoFailover = true;
  var _ruleMode = true;
  var _holdTraffic = true;
  var _busy = false;
  var _running = false;
  var _status = '未连接';
  var _detail = '还没有节点，请先在设置里添加';
  var _mode = '';
  var _up = 0;
  var _down = 0;
  DateTime? _connectedAt;
  Timer? _timer;
  var _appliedProxy = false;
  var _nav = 0;
  var _didAutoConnect = false;
  var _closing = false;
  var _userStop = false;
  var _switching = false;
  var _sawReconnect = false;
  var _failAnnounced = false;
  DateTime? _unstableSince;
  final _skipped = <String>{};
  Timer? _subTimer;
  Timer? _quotaTimer;
  Timer? _netTimer;
  Timer? _ifaceTimer;
  var _netSig = '';
  var _quotaLine = '';
  var _quotaWarn = false;
  var _speedBusy = false;
  var _speedPing = '—';
  var _speedDown = '—';
  var _speedUp = '—';
  var _quietStart = false;
  var _subError = '';
  final _startedAt = DateTime.now();
  final _recentLog = <String>[];

  @override
  void initState() {
    super.initState();
    AppLang.I.addListener(_onLang);
    WindowChrome.beforeQuit = _cleanupExit;
    _quietStart = Platform.executableArguments.contains('--quiet');
    DesktopHost.listen(
      onShow: () async {},
      onToggle: _toggle,
      onQuit: () async {
        await _cleanupExit();
        await DesktopHost.quit();
      },
      onNetworkChanged: _onNetworkChanged,
      onSessionUnlock: _onSessionUnlock,
    );
    _load();
    _ifaceTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollIfaces());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final http = prefs.getInt('http') ?? 8080;
    if (!_running && !_appliedProxy) {
      await SystemProxy.clearLocal();
    }
    if (!mounted) return;
    final book = await NodeBook.load(prefs);
    final node = book.active;
    if (_running && (node?.endpoint ?? '') != _endpoint) {
      await _disconnect();
    }
    if (!mounted) return;
    setState(() {
      _nodes = List<VpnNode>.of(book.nodes);
      _activeId = node?.id ?? '';
      _endpoint = node?.endpoint ?? '';
      _token = node?.token ?? '';
      _nodeName = node?.name ?? '';
      _exitVia = node?.exitVia ?? 'landing';
      _vpsIp = node?.vpsIp ?? '';
      if (!_running) {
        _detail = _endpoint.isEmpty ? '还没有节点，请先在设置里添加' : '点击连接即可使用';
      }
      _socks = prefs.getInt('socks') ?? 1080;
      _http = http;
      _preferH3 = prefs.getBool('prefer_h3') ?? true;
      _cfBestOn = prefs.getBool('cf_best_on') ?? true;
      _cfBestIp = prefs.getString('cf_best_ip') ?? '';
      _cfBestMs = prefs.getInt('cf_best_ms') ?? 0;
      _cfBestColo = prefs.getString('cf_best_colo') ?? '';
      _cfBestHost = prefs.getString('cf_best_host') ?? '';
      _cfBestAt = prefs.getInt('cf_best_at') ?? 0;
      _fetchEnabled = prefs.getBool('fetch_enabled') ?? false;
      _systemProxy = prefs.getBool('system_proxy') ?? !Platform.isAndroid;
      _bypass = _readBypass(prefs);
      _autoConnect = prefs.getBool('auto_connect') ?? false;
      _autoFailover = prefs.getBool('auto_failover') ?? true;
      _ruleMode = prefs.getBool('rule_mode') ?? true;
      _holdTraffic = prefs.getBool('hold_traffic') ?? true;
      _quotaLine = prefs.getString('worker_usage_home') ?? '';
      _subError = prefs.getString('sub_last_error') ?? '';
    });
    _subTimer ??= Timer.periodic(subRefreshEvery, (_) => _refreshSub(silent: true));
    if (await subscriptionIsStale()) {
      await _refreshSub(silent: true);
      if (!mounted) return;
      final again = await NodeBook.load();
      final current = again.active;
      setState(() {
        _nodes = List<VpnNode>.of(again.nodes);
        if (current != null && current.endpoint != _endpoint) {
          _activeId = current.id;
          _endpoint = current.endpoint;
          _token = current.token;
          _nodeName = current.name;
          _exitVia = current.exitVia;
          _vpsIp = current.vpsIp;
        }
      });
    }
    if (!_didAutoConnect && (_autoConnect || _quietStart) && !_running && !_busy) {
      _didAutoConnect = true;
      if (_endpoint.startsWith('https://') && _token.isNotEmpty) {
        unawaited(_connect());
      }
    }
  }

  Future<void> _onSettingsSaved() async {
    final running = _running;
    await _load();
    if (!mounted || !running) return;
    await _reapplyRuntime();
  }

  Map<String, dynamic> _configJson() => {
        'endpoint': _endpoint,
        'token': _token,
        'socks_port': _socks,
        'http_port': _http,
        'prefer_h3': _preferH3,
        if (_cfBestOn && _cfBestIp.isNotEmpty && usesCloudflarePath(_exitVia, Uri.tryParse(_endpoint)?.host ?? ''))
          'connect_ip': _cfBestIp,
        'fetch_enabled': _fetchEnabled,
        'exit_via': _exitVia,
        if (_udpReady) 'udp_host': _vpsIp,
        if (_udpReady) 'udp_port': 8444,
        'bypass': _bypass,
        'rule_mode': _ruleMode,
      };

  Future<void> _ensureBestIp() async {
    final host = Uri.tryParse(_endpoint)?.host ?? '';
    if (!_cfBestOn || !usesCloudflarePath(_exitVia, host)) return;
    // 已经选过的地址直接连，不再先做一遍探测。探测会把连接时间拉长一倍。
    if (_cfBestIp.isNotEmpty && _cfBestHost == host) return;
    if (mounted) {
      setState(() => _detail = '正在优选 Cloudflare IP');
    }
    final CfBestIp pick;
    try {
      pick = await pickCloudflareIp(
        host: host,
        token: _token,
        onProgress: (text) {
          if (mounted) setState(() => _detail = text);
        },
      );
    } on CfBestIpException {
      await _clearBestIp();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cf_best_ip', pick.ip);
    await prefs.setInt('cf_best_ms', pick.ms);
    await prefs.setString('cf_best_colo', pick.colo);
    await prefs.setString('cf_best_host', host);
    await prefs.setInt('cf_best_at', DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() {
      _cfBestIp = pick.ip;
      _cfBestMs = pick.ms;
      _cfBestColo = pick.colo;
      _cfBestHost = host;
      _cfBestAt = DateTime.now().millisecondsSinceEpoch;
    });
  }

  Future<void> _clearBestIp() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cf_best_ip');
    await prefs.remove('cf_best_ms');
    await prefs.remove('cf_best_colo');
    await prefs.remove('cf_best_host');
    await prefs.remove('cf_best_at');
    if (!mounted) return;
    setState(() {
      _cfBestIp = '';
      _cfBestMs = 0;
      _cfBestColo = '';
      _cfBestHost = '';
      _cfBestAt = 0;
    });
  }

  Future<void> _reapplyRuntime() async {
    try {
      final core = RsqCore.open();
      core.stop();
      final error = core.start(jsonEncode(_configJson()));
      if (error != null) {
        setState(() {
          _running = false;
          _status = '未连接';
          _detail = error;
        });
        return;
      }
      if (_systemProxy) {
        final proxyError = await SystemProxy.enable(_http, bypass: _bypass, socksPort: _socks);
        _appliedProxy = proxyError == null;
      }
    } catch (_) {}
  }

  Future<void> _cleanupExit() async {
    if (_closing) return;
    _closing = true;
    _userStop = true;
    _timer?.cancel();
    _subTimer?.cancel();
    _quotaTimer?.cancel();
    _netTimer?.cancel();
    _ifaceTimer?.cancel();
    try {
      RsqCore.open().stop();
    } catch (_) {}
    await SystemProxy.clearLocal();
    _appliedProxy = false;
  }

  void _onLang() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppLang.I.removeListener(_onLang);
    _timer?.cancel();
    _subTimer?.cancel();
    _quotaTimer?.cancel();
    _netTimer?.cancel();
    _ifaceTimer?.cancel();
    if (WindowChrome.beforeQuit == _cleanupExit) {
      WindowChrome.beforeQuit = null;
    }
    super.dispose();
  }

  void _note(String line) {
    _recentLog.insert(0, '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')} $line');
    if (_recentLog.length > 20) _recentLog.removeRange(20, _recentLog.length);
    unawaited(DesktopHost.setTrayTip('跳跳猴 · $line'));
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_running || _busy) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _refreshSub({required bool silent}) async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('sub_url')?.trim() ?? '';
    if (url.isEmpty) return;
    try {
      final message = await updateSubscription(url);
      _subError = '';
      if (!silent && mounted) _show(message);
      _note(message);
    } on SubscriptionException catch (err) {
      _subError = err.message;
      if (!silent && mounted) _show(err.message);
      _note('订阅失败，稍后会再试');
    } catch (_) {
      _subError = '订阅更新失败';
      if (!silent && mounted) _show('订阅更新失败');
    }
  }

  Future<void> _connect() async {
    if (_closing) return;
    _userStop = false;
    if (!_switching) {
      _skipped.clear();
      _failAnnounced = false;
      _sawReconnect = false;
      _unstableSince = null;
    }
    if (!_endpoint.startsWith('https://') || _token.isEmpty) {
      _show('还没有节点，先在左侧「节点」里添加或选用一条');
      setState(() => _nav = 1);
      return;
    }
    VpnNode? current;
    for (final node in _nodes) {
      if (node.id == _activeId) current = node;
    }
    if (current?.shareExpired == true) {
      _show('这条分享已经过期');
      return;
    }
    if ((current?.shareId ?? '').isNotEmpty) {
      final ledger = await ShareBook.load();
      if (ledger.blocked(current!.shareId)) {
        _show('这条分享已被停用');
        return;
      }
    }
    setState(() {
      _busy = true;
      _status = '正在连接';
      _detail = '正在接入节点';
    });
    try {
      await _ensureBestIp();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '未连接';
        _detail = '$err';
      });
      return;
    }
    late final RsqCore core;
    try {
      core = RsqCore.open();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '未连接';
        _detail = '$err';
      });
      return;
    }
    final error = core.start(jsonEncode(_configJson()));
    if (error != null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '未连接';
        _detail = error;
      });
      return;
    }
    if (Platform.isAndroid) await _signal('start');
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _poll());
    await _poll();
  }

  Future<void> _poll() async {
    if (_closing || !mounted) return;
    Map<String, dynamic> stats;
    try {
      stats = RsqCore.open().stats();
    } catch (_) {
      return;
    }
    if (!mounted || _closing) return;
    final phase = stats['phase'] as String? ?? 'down';
    final error = stats['error'] as String? ?? '';
    if (phase == 'reconnecting') {
      if (!mounted || _closing) return;
      _unstableSince ??= DateTime.now();
      final fresh = _status != '正在重连';
      if (fresh) {
        _sawReconnect = true;
        _note(error.isEmpty ? '正在重连' : '正在重连：$error');
        unawaited(DesktopHost.notify(title: '跳跳猴', body: '连接中断，正在重连'));
      }
      setState(() {
        _busy = false;
        _running = true;
        _status = '正在重连';
        _detail = error.isEmpty ? '心跳中断，正在自动恢复' : error;
        _up = _asInt(stats['bytes_up']);
        _down = _asInt(stats['bytes_down']);
      });
      final waited = DateTime.now().difference(_unstableSince!);
      if (!_userStop && waited >= const Duration(seconds: 20)) {
        if (_autoFailover) {
          unawaited(_tryFailover());
        } else if (!_failAnnounced) {
          _failAnnounced = true;
          _note('重连失败');
          unawaited(DesktopHost.notify(title: '跳跳猴', body: '重连失败，仍在尝试当前节点'));
        }
      }
      return;
    }
    if (phase == 'up') {
      if (_closing) return;
      if (_systemProxy && !_appliedProxy) {
        final proxyError = await SystemProxy.enable(_http, bypass: _bypass, socksPort: _socks);
        if (_closing) {
          await SystemProxy.clearLocal();
          return;
        }
        _appliedProxy = proxyError == null;
        if (proxyError != null && mounted) _show(proxyError);
      }
      if (!mounted || _closing) return;
      final wasUp = _status == '已连接';
      final recovered = _sawReconnect;
      setState(() {
        _busy = false;
        _running = true;
        _connectedAt ??= DateTime.now();
        _mode = stats['mode'] as String? ?? '';
        _status = '已连接';
        _detail = protocolLabel(_mode);
        _up = _asInt(stats['bytes_up']);
        _down = _asInt(stats['bytes_down']);
      });
      _unstableSince = null;
      _failAnnounced = false;
      _sawReconnect = false;
      _skipped.clear();
      if (recovered) {
        _note('已恢复');
        unawaited(DesktopHost.notify(title: '跳跳猴', body: '已恢复'));
      } else if (!wasUp) {
        _note('已连接 ${_detail}');
        _armQuota();
      }
      return;
    }
    if (phase == 'down' && error.isNotEmpty) {
      if (_userStop) {
        _timer?.cancel();
        return;
      }
      if (_autoFailover && !_failAnnounced) {
        _sawReconnect = true;
        unawaited(_tryFailover());
        return;
      }
      _timer?.cancel();
      if (_appliedProxy && !_holdTraffic) {
        await SystemProxy.disable(_http);
        _appliedProxy = false;
      }
      if (!mounted) return;
      final wasRunning = _running || _sawReconnect;
      setState(() {
        _busy = false;
        _running = false;
        _connectedAt = null;
        _status = '未连接';
        _detail = _holdTraffic && _appliedProxy ? '已经拦住，不会走真实网络' : error;
      });
      if (wasRunning && !_failAnnounced) {
        _failAnnounced = true;
        _note(_holdTraffic && _appliedProxy ? '已拦住，没有改走真实网络' : '重连失败：$error');
        unawaited(DesktopHost.notify(title: '跳跳猴', body: _holdTraffic && _appliedProxy ? '已拦住' : '重连失败'));
      }
    }
  }

  Future<void> _tryFailover() async {
    if (_switching || _userStop || _failAnnounced) return;
    _switching = true;
    try {
      final book = await NodeBook.load();
      final current = book.active;
      if (current != null) _skipped.add(current.id);
      VpnNode? pick;
      for (final node in book.nodes) {
        if (_skipped.contains(node.id) || !node.ready) continue;
        final probe = await probeNode(node);
        if (probe.ok) {
          pick = node;
          break;
        }
        _skipped.add(node.id);
      }
      if (pick == null) {
        _failAnnounced = true;
        _note('重连失败，没有其他可用节点');
        unawaited(DesktopHost.notify(title: '跳跳猴', body: '重连失败'));
        if (_appliedProxy && !_holdTraffic) {
          await SystemProxy.disable(_http);
          _appliedProxy = false;
        }
        if (!mounted) return;
        setState(() {
          _busy = false;
          _running = true;
          _status = '正在重连';
          _detail = _holdTraffic && _appliedProxy ? '没有其他节点。流量已拦住' : '没有其他可用节点，仍在尝试当前节点';
        });
        return;
      }
      final next = pick;
      book.select(next.id);
      await book.save();
      _unstableSince = DateTime.now();
      _note('已切换到 ${next.name}');
      unawaited(DesktopHost.notify(title: '跳跳猴', body: '已切换到 ${next.name}'));
      if (!mounted) return;
      setState(() {
        _activeId = next.id;
        _endpoint = next.endpoint;
        _token = next.token;
        _nodeName = next.name;
        _exitVia = next.exitVia;
        _vpsIp = next.vpsIp;
      });
      await _connect();
    } finally {
      _switching = false;
    }
  }

  Future<void> _disconnect() async {
    _userStop = true;
    _switching = false;
    _unstableSince = null;
    _sawReconnect = false;
    _timer?.cancel();
    _quotaTimer?.cancel();
    setState(() {
      _busy = true;
      _status = '正在断开';
    });
    try {
      RsqCore.open().stop();
    } catch (_) {}
    if (_appliedProxy) {
      await SystemProxy.disable(_http);
      _appliedProxy = false;
    }
    if (Platform.isAndroid) await _signal('stop');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _running = false;
      _connectedAt = null;
      _mode = '';
      _status = '未连接';
      _detail = '点击连接即可使用';
      _speedPing = '—';
      _speedDown = '—';
      _speedUp = '—';
    });
  }

  Future<void> _signal(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {}
  }

  void _show(String text) {
    if (!mounted) return;
    showTicketSnack(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPaper,
      body: DotGrid(
        child: Row(
          children: [
            _SideBar(
              selected: _nav,
              compact: MediaQuery.sizeOf(context).width < 960,
              onSelect: (index) {
                setState(() => _nav = index);
                if (index == 0) unawaited(_refreshNodes());
              },
            ),
            Expanded(
              child: IndexedStack(
                index: _nav == 0 ? 0 : 1,
                children: [
                  _overview(),
                  SettingsPage(
                    endpoint: _endpoint,
                    token: _token,
                    nodeName: _nodeName,
                    socks: _socks,
                    http: _http,
                    preferH3: _preferH3,
                    cfBestOn: _cfBestOn,
                    cfBestIp: _cfBestIp,
                    cfBestMs: _cfBestMs,
                    cfBestColo: _cfBestColo,
                    fetchEnabled: _fetchEnabled,
                    exitVia: _exitVia,
                    systemProxy: _systemProxy,
                    bypass: _bypass,
                    autoConnect: _autoConnect,
                    autoFailover: _autoFailover,
                    ruleMode: _ruleMode,
                    holdTraffic: _holdTraffic,
                    running: _running,
                    connecting: _busy || _status == '正在重连',
                    vpsIp: _vpsIp,
                    recentLog: _recentLog,
                    panel: _nav == 0 ? 1 : _nav,
                    onSaved: _onSettingsSaved,
                    onConnect: _connectFromList,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _udpReady => _vpsIp.isNotEmpty && _exitVia != 'direct';

  Future<void> _pollIfaces() async {
    try {
      final parts = <String>[];
      for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        final addrs = iface.addresses.map((a) => a.address).toList()..sort();
        parts.add('${iface.name}:${addrs.join(',')}');
      }
      parts.sort();
      final sig = parts.join('|');
      if (_netSig.isEmpty) {
        _netSig = sig;
        return;
      }
      if (sig == _netSig) return;
      _netSig = sig;
      await _onNetworkChanged();
    } catch (_) {}
  }

  Future<void> _onNetworkChanged() async {
    if (DateTime.now().difference(_startedAt) < const Duration(seconds: 5)) return;
    _netTimer?.cancel();
    _netTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted || _closing || _userStop) return;
      if (_running || _status == '正在重连') {
        _note('网络已切换，正在恢复');
        await _reapplyRuntime();
        return;
      }
      if (_autoConnect || _quietStart) {
        await _connect();
      }
    });
  }

  Future<void> _onSessionUnlock() async {
    if (!mounted || _closing || !_running || !_systemProxy) return;
    final proxyError = await SystemProxy.enable(_http, bypass: _bypass, socksPort: _socks);
    _appliedProxy = proxyError == null;
  }

  Future<void> _refreshQuota({bool force = false}) async {
    if (_exitVia == 'vps' || _exitVia == 'cdn') return;
    final usage = await fetchWorkerUsage(allowCache: !force);
    if (!mounted) return;
    if (usage.homeLine.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('worker_usage_home', usage.homeLine);
    setState(() {
      _quotaLine = usage.homeLine;
      _quotaWarn = usage.warn;
    });
    if (!usage.warn) return;
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final key = usage.blocked ? 'quota_block_day' : 'quota_warn_day';
    if (prefs.getString(key) == day) return;
    await prefs.setString(key, day);
    _show(usage.homeLine);
    unawaited(DesktopHost.notify(title: '跳跳猴', body: usage.homeLine));
  }

  void _armQuota() {
    _quotaTimer?.cancel();
    unawaited(_refreshQuota());
    _quotaTimer = Timer.periodic(const Duration(minutes: 12), (_) => _refreshQuota(force: true));
  }

  Future<void> _refreshNodes() async {
    final book = await NodeBook.load();
    if (!mounted) return;
    final node = book.active;
    setState(() {
      _nodes = List<VpnNode>.of(book.nodes);
      _activeId = node?.id ?? _activeId;
      if (!_running && !_busy && node != null) {
        _endpoint = node.endpoint;
        _token = node.token;
        _nodeName = node.name;
        _exitVia = node.exitVia;
        _vpsIp = node.vpsIp;
        _activeId = node.id;
      }
    });
  }

  Future<void> _connectFromList(VpnNode node) async {
    if (_closing || _busy) return;
    if (!node.ready) {
      _show('这条节点不完整，先编辑填好');
      return;
    }
    final same = node.id == _activeId;
    if (!same) {
      final book = await NodeBook.load();
      book.select(node.id);
      await book.save();
      if (!mounted) return;
      setState(() {
        _nodes = List<VpnNode>.of(book.nodes);
        _activeId = node.id;
        _endpoint = node.endpoint;
        _token = node.token;
        _nodeName = node.name;
        _exitVia = node.exitVia;
        _vpsIp = node.vpsIp;
      });
    }
    if (_running && same) {
      setState(() => _nav = 0);
      return;
    }
    if (_running) await _disconnect();
    if (!mounted) return;
    setState(() => _nav = 0);
    await _connect();
  }

  Future<void> _pickNode(VpnNode node) async {
    if (_busy || node.id == _activeId) return;
    final book = await NodeBook.load();
    book.select(node.id);
    await book.save();
    if (!mounted) return;
    final wasRunning = _running;
    setState(() {
      _nodes = List<VpnNode>.of(book.nodes);
      _activeId = node.id;
      _endpoint = node.endpoint;
      _token = node.token;
      _nodeName = node.name;
      _exitVia = node.exitVia;
      _vpsIp = node.vpsIp;
      if (!wasRunning) {
        _detail = '点击连接即可使用';
      }
    });
    if (!wasRunning) return;
    await _disconnect();
    if (!mounted) return;
    await _connect();
  }

  String _nodeLabel(VpnNode node) {
    final base = node.name.trim().isEmpty ? node.host : node.name.trim();
    final same = _nodes.where((item) {
      final label = item.name.trim().isEmpty ? item.host : item.name.trim();
      return label == base;
    }).length;
    if (same < 2 || node.host.isEmpty) return base;
    return '$base · ${node.host}';
  }

  Widget _nodeStrip() {
    if (_nodes.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkChip(label: tx('去添加节点', 'Add a node'), onTap: () => setState(() => _nav = 1)),
      );
    }
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _nodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final node = _nodes[index];
          final selected = node.id == _activeId;
          final connecting = selected && (_busy || _status == '正在重连');
          final flag = countryCodeOf(_nodeLabel(node));
          return InkChip(
            label: _nodeLabel(node),
            selected: selected,
            icon: connecting
                ? const ConnectMark()
                : flag == null
                    ? (selected ? const Icon(Icons.check_rounded, size: 14) : null)
                    : FlagMark(flag, height: 12),
            onTap: _busy ? null : () => _pickNode(node),
          );
        },
      ),
    );
  }

  String get _headline {
    if (_busy) return tx('正在连接.', 'Connecting.');
    if (_status == '正在重连') return tx('正在重连.', 'Reconnecting.');
    if (_running) return tx('已经连上.', 'Connected.');
    return tx('一键接入.', 'Connect.');
  }

  String _showStatus(String status) {
    switch (status) {
      case '未连接':
        return tx('未连接', 'Offline');
      case '已连接':
        return tx('已连接', 'Connected');
      case '正在连接':
        return tx('正在连接', 'Connecting');
      case '正在重连':
        return tx('正在重连', 'Reconnecting');
      case '正在断开':
        return tx('正在断开', 'Disconnecting');
      default:
        return status;
    }
  }

  Widget _overview() {
    final host = Uri.tryParse(_endpoint)?.host ?? '';
    final name = _nodeName.isEmpty ? (host.isEmpty ? '还没有节点' : '未命名节点') : _nodeName;
    final connecting = _busy || _status == '正在重连';
    final action = connecting ? _showStatus(_status) : (_running ? tx('断开', 'Stop') : tx('开始连接', 'Connect'));
    return LayoutBuilder(
      builder: (context, box) {
        final short = box.maxHeight < 660;
        final narrow = box.maxWidth < 700;
        return Padding(
          padding: EdgeInsets.fromLTRB(narrow ? 20 : 32, short ? 16 : 24, narrow ? 20 : 40, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const YouBadge('YOU'),
              SizedBox(height: short ? 6 : 10),
              Text(_headline, style: kDisplay.copyWith(fontSize: short ? 32 : 44)),
              if (!_running && !_busy) ...[
                const SizedBox(height: 4),
                Text(_showStatus(_status), style: const TextStyle(color: kMute, fontSize: 18, fontWeight: FontWeight.w700)),
              ],
              SizedBox(height: short ? 6 : 8),
              MintLine(width: short ? 120 : 168),
              SizedBox(height: short ? 10 : 16),
              Row(
                children: [
                  const AppIcon('link.svg', size: 16),
                  const SizedBox(width: 6),
                  Text(tx('选择节点', 'Nodes'), style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 15)),
                ],
              ),
              const SizedBox(height: 10),
              _nodeStrip(),
              const SizedBox(height: 10),
              SupportStrip(exitVia: host.isEmpty ? '' : _exitVia, udp: host.isNotEmpty && _udpReady),
              const SizedBox(height: 8),
              if (host.isEmpty) ...[
                Text(tx('还没有节点，请先在设置里添加', 'No node yet. Add one in settings.'), style: const TextStyle(color: kMute, fontSize: 15, height: 1.4)),
                const SizedBox(height: 2),
                Text(tx('特别感谢 Cloudflare 的支持', 'Thanks to Cloudflare'), style: const TextStyle(color: kMute, fontSize: 15, height: 1.4)),
              ] else if (Platform.isAndroid && (_running || host.isNotEmpty))
                Text(tx('手机里填 127.0.0.1:$_socks', 'On this phone use 127.0.0.1:$_socks'), style: const TextStyle(color: kMute, fontSize: 15, height: 1.4))
              else if (_running && _udpReady)
                Text('${tx('游戏用', 'Games')} 127.0.0.1:$_socks', style: const TextStyle(color: kMute, fontSize: 15, height: 1.4)),
              const SizedBox(height: 12),
              Expanded(
                child: TicketShell(
                  onTap: _toggle,
            stub: GoldStub(
              kicker: _running ? 'ON' : 'OFF',
              big: _running ? '开' : '关',
              foot: connecting ? '请稍候' : (_running ? _clock() : '点一下'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusDot(live: _running && !connecting, busy: connecting),
                    const SizedBox(width: 10),
                    if (countryCodeOf(name) != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FlagMark(countryCodeOf(name)!, height: 16),
                      )
                    else ...[
                      const AppIcon('server.svg', size: 16),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk),
                      ),
                    ),
                    if (connecting) const ConnectMark(size: 22, color: kInk),
                  ],
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: () {},
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      _speedFact(Icons.schedule_rounded, tx('延迟', 'Ping'), _speedPing),
                      _speedFact(Icons.arrow_downward_rounded, tx('下载', 'Down'), _speedDown),
                      _speedFact(Icons.arrow_upward_rounded, tx('上传', 'Up'), _speedUp),
                      FilledButton.icon(
                        onPressed: (_speedBusy || connecting) ? null : _runSpeed,
                        icon: Icon(_speedBusy ? Icons.hourglass_top_rounded : Icons.speed_rounded, size: 16),
                        label: Text(_speedBusy ? tx('测速中', 'Testing') : tx('测速', 'Speed')),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    const AppIcon('power.svg', size: 26),
                    const SizedBox(width: 10),
                    Text(action, style: TextStyle(fontSize: short ? 28 : 36, fontWeight: FontWeight.w800, height: 1, color: kInk)),
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {},
                  behavior: HitTestBehavior.opaque,
                  child: _bestIpRow(host, connecting),
                ),
              ],
            ),
                ),
              ),
          const SizedBox(height: 10),
          _InfoCard(
            up: _up,
            down: _down,
            running: _running,
            clock: _running ? _clock() : '—',
            quota: _quotaShort,
            quotaWarn: _quotaWarn,
          ),
            ],
          ),
        );
      },
    );
  }

  Widget _bestIpRow(String host, bool connecting) {
    final cloud = usesCloudflarePath(_exitVia, host);
    final label = host.isEmpty
        ? tx('先去「节点」加一条', 'Add a node first')
        : (connecting
            ? '${tx('正在接入', 'Joining')} $host'
            : (_cfBestOn && _cfBestIp.isNotEmpty && cloud
                ? '$host · ${tx('优选', 'Best')} $_cfBestIp${_cfBestMs > 0 ? ' ${_cfBestMs}ms' : ''}'
                : host));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const AppIcon('globe.svg', size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _cfPicking ? tx('正在换优选地址', 'Switching address') : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kMute, height: 1.2, fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        if (cloud) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const AppIcon('cloud.svg', size: 16),
              const SizedBox(width: 6),
              Text(tx('优选 IP', 'Best IP'), style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 14)),
              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.82,
                child: Switch(
                  value: _cfBestOn,
                  onChanged: _cfPicking || connecting ? null : (value) => unawaited(_setHomeBestIp(value)),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: (!_cfBestOn || _cfPicking || connecting) ? null : () => unawaited(_switchHomeBestIp()),
                child: Text(_cfPicking ? tx('扫描中', 'Scanning') : tx('换一个', 'Another')),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _setHomeBestIp(bool value) async {
    setState(() => _cfBestOn = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cf_best_on', value);
    if (value && _cfBestIp.isEmpty) {
      await _switchHomeBestIp(skipCurrent: false);
      return;
    }
    if (_running) await _reapplyRuntime();
  }

  Future<void> _switchHomeBestIp({bool skipCurrent = true}) async {
    final host = Uri.tryParse(_endpoint)?.host ?? '';
    if (!usesCloudflarePath(_exitVia, host)) {
      _show(tx('当前出口不用优选 IP', 'This exit does not use a Cloudflare address'));
      return;
    }
    setState(() {
      _cfPicking = true;
      _cfBestOn = true;
    });
    try {
      final pick = await pickCloudflareIp(
        host: host,
        token: _token,
        skip: skipCurrent && _cfBestIp.isNotEmpty ? {_cfBestIp} : const {},
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('cf_best_on', true);
      await prefs.setString('cf_best_ip', pick.ip);
      await prefs.setInt('cf_best_ms', pick.ms);
      await prefs.setString('cf_best_colo', pick.colo);
      await prefs.setString('cf_best_host', host);
      await prefs.setInt('cf_best_at', DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      setState(() {
        _cfBestIp = pick.ip;
        _cfBestMs = pick.ms;
        _cfBestColo = pick.colo;
        _cfBestHost = host;
        _cfBestAt = DateTime.now().millisecondsSinceEpoch;
      });
      if (_running) await _reapplyRuntime();
      if (mounted) _show('${tx('已换成', 'Now')} ${pick.ip}');
    } on CfBestIpException catch (err) {
      if (mounted) _show('$err');
    } catch (err) {
      if (mounted) _show('$err');
    } finally {
      if (mounted) setState(() => _cfPicking = false);
    }
  }

  Widget _speedFact(IconData icon, String label, String value) {
    return Expanded(
      child: Row(
        children: [
          Icon(icon, size: 18, color: kInk),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: kMute, fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                value == '…'
                    ? const SpeedDots()
                    : Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kInk, fontSize: 16, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runSpeed() async {
    if (!_running) {
      _show('先连上，再测现在这条');
      return;
    }
    VpnNode? node;
    for (final item in _nodes) {
      if (item.id == _activeId) node = item;
    }
    if (node == null || !node.ready) {
      _show('还没有正在用的节点');
      return;
    }
    setState(() {
      _speedBusy = true;
      _speedPing = '…';
      _speedDown = '…';
      _speedUp = '…';
    });
    final pinned = _cfBestOn && _cfBestIp.isNotEmpty && usesCloudflarePath(node.exitVia, node.host);
    final SpeedSample ping;
    if (pinned) {
      final ms = await pingCloudflareIp(ip: _cfBestIp, host: node.host, token: node.token);
      ping = ms == null
          ? (_cfBestMs > 0 ? SpeedSample(ok: true, label: '${_cfBestMs}ms') : const SpeedSample(ok: false, label: '失败'))
          : SpeedSample(ok: true, label: '${ms}ms');
      if (ms != null) {
        _cfBestMs = ms;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('cf_best_ms', ms);
      }
    } else {
      ping = await measurePing(node.host);
    }
    if (!mounted || !_running) {
      if (mounted) setState(() => _speedBusy = false);
      return;
    }
    setState(() => _speedPing = ping.label);
    final down = await measureDownload(
      _http,
      shouldStop: () => !mounted || !_running,
      onProgress: (label) {
        if (mounted) setState(() => _speedDown = label);
      },
    );
    if (!mounted) return;
    setState(() => _speedDown = down.label);
    if (!_running) {
      setState(() => _speedBusy = false);
      return;
    }
    final up = await measureUpload(
      _http,
      shouldStop: () => !mounted || !_running,
      onProgress: (label) {
        if (mounted) setState(() => _speedUp = label);
      },
    );
    if (!mounted) return;
    setState(() {
      _speedBusy = false;
      _speedUp = up.label;
    });
  }

  String get _quotaShort {
    if (_quotaLine.isEmpty) return '—';
    final match = RegExp(r'\d+%').firstMatch(_quotaLine);
    if (match != null && !_quotaWarn) return match.group(0)!;
    if (_quotaLine.contains('已用完')) return '已用完';
    if (_quotaLine.contains('快用完')) return '快用完';
    return match?.group(0) ?? '—';
  }

  String _clock() {
    final start = _connectedAt;
    if (start == null) return '00:00:00';
    final d = DateTime.now().difference(start);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

}

class _SideBar extends StatelessWidget {
  const _SideBar({required this.selected, required this.onSelect, this.compact = false});

  final int selected;
  final ValueChanged<int> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('power.svg', tx('连接', 'Home')),
      ('link.svg', tx('节点', 'Nodes')),
      ('download.svg', tx('导入', 'Import')),
      ('cloud.svg', tx('搭建', 'Setup')),
      ('settings.svg', tx('本机', 'Device')),
    ];
    return SizedBox(
      width: compact ? 156 : 188,
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 22, compact ? 8 : 12, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(width: 10),
                const Flexible(
                  child: Text('跳跳猴', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kInk, fontSize: 20, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 28),
            for (var i = 0; i < items.length; i++) ...[
              _NavTile(
                icon: items[i].$1,
                label: items[i].$2,
                selected: selected == i,
                onTap: () => onSelect(i),
              ),
              const SizedBox(height: 6),
            ],
            const Spacer(),
            const YouBadge('APP'),
            const SizedBox(height: 8),
            Text(tx('一只会跳跳的猴子', 'A monkey that hops'), style: const TextStyle(color: kMute, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap});

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? kInk : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              AppIcon(icon, color: selected ? Colors.white : kInk, size: 18),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(color: selected ? Colors.white : kInk, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class SpeedDots extends StatefulWidget {
  const SpeedDots({super.key});

  @override
  State<SpeedDots> createState() => _SpeedDotsState();
}

class _SpeedDotsState extends State<SpeedDots> with SingleTickerProviderStateMixin {
  late final AnimationController _tick;

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _tick,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            final wave = ((_tick.value + i / 3) % 1.0);
            final t = wave < 0.5 ? wave * 2 : (1 - wave) * 2;
            return Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Opacity(
                opacity: 0.18 + 0.82 * t,
                child: Transform.translate(
                  offset: Offset(0, -3 * t),
                  child: const Text(
                    '·',
                    style: TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w900, height: 1),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.live, required this.busy});

  final bool live;
  final bool busy;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _tick;

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    if (widget.busy) _tick.repeat();
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !_tick.isAnimating) {
      _tick.repeat();
    } else if (!widget.busy && _tick.isAnimating) {
      _tick.stop();
    }
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.live ? const Color(0xFF2F9E44) : (widget.busy ? kInk : kMute);
    if (!widget.busy) {
      return Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    }
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          final t = _tick.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 8 + 6 * t,
                height: 8 + 6 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 1 - t), width: 1.4),
                ),
              ),
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ],
          );
        },
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.up,
    required this.down,
    required this.running,
    required this.clock,
    required this.quota,
    this.quotaWarn = false,
  });

  final int up;
  final int down;
  final bool running;
  final String clock;
  final String quota;
  final bool quotaWarn;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: kTicket,
      child: Row(
        children: [
          _cell(tx('流量', 'Traffic'), running ? '↑ ${_kb(up)}  ↓ ${_kb(down)}' : '—'),
          _cell(tx('时长', 'Time'), clock),
          _cell(tx('今日额度', 'Today'), quota, warn: quotaWarn && running),
        ],
      ),
    );
  }

  Widget _cell(String label, String value, {bool warn = false}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kMute, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: warn ? const Color(0xFFB42318) : kInk, fontWeight: FontWeight.w800, fontSize: 18),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.endpoint,
    required this.token,
    required this.nodeName,
    required this.socks,
    required this.http,
    required this.preferH3,
    this.cfBestOn = true,
    this.cfBestIp = '',
    this.cfBestMs = 0,
    this.cfBestColo = '',
    this.fetchEnabled = false,
    required this.exitVia,
    required this.systemProxy,
    this.bypass = const [],
    this.autoConnect = false,
    this.autoFailover = true,
    this.ruleMode = true,
    this.holdTraffic = true,
    this.running = false,
    this.connecting = false,
    this.vpsIp = '',
    this.recentLog = const [],
    this.panel = 0,
    this.onSaved,
    this.onConnect,
  });

  final String endpoint;
  final String token;
  final String nodeName;
  final int socks;
  final int http;
  final bool preferH3;
  final bool cfBestOn;
  final String cfBestIp;
  final int cfBestMs;
  final String cfBestColo;
  final bool fetchEnabled;
  final String exitVia;
  final bool systemProxy;
  final List<String> bypass;
  final bool autoConnect;
  final bool autoFailover;
  final bool ruleMode;
  final bool holdTraffic;
  final bool running;
  final bool connecting;
  final String vpsIp;
  final List<String> recentLog;
  final int panel;
  final Future<void> Function()? onSaved;
  final Future<void> Function(VpnNode node)? onConnect;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _nodeName;
  late final TextEditingController _apiToken;
  late final TextEditingController _domain;
  late final TextEditingController _vpsIp;
  late final TextEditingController _vpsPassword;
  late final TextEditingController _socks;
  late final TextEditingController _http;
  late final TextEditingController _shareIn;
  late final TextEditingController _bypassIn;
  late final TextEditingController _subUrl;
  late bool _preferH3;
  late bool _cfBestOn;
  var _cfBestIp = '';
  var _cfBestMs = 0;
  var _cfBestColo = '';
  var _cfPicking = false;
  late bool _fetchEnabled;
  late String _exitVia;
  late bool _systemProxy;
  late bool _autoConnect;
  late bool _autoFailover;
  late bool _ruleMode;
  late bool _holdTraffic;
  late bool _launchAtStartup;
  late List<String> _bypass;
  var _obscureApi = true;
  var _obscureVps = true;
  var _deploying = false;
  var _deployStatus = '';
  var _setupTab = 0;
  var _diagBusy = false;
  var _subBusy = false;
  var _subError = '';
  String _diagText = '';
  final _deployLog = <String>[];
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _endpoint = TextEditingController(text: widget.endpoint);
    _token = TextEditingController(text: widget.token);
    _nodeName = TextEditingController(text: widget.nodeName);
    _apiToken = TextEditingController();
    _domain = TextEditingController();
    _vpsIp = TextEditingController();
    _vpsPassword = TextEditingController();
    _socks = TextEditingController(text: '${widget.socks}');
    _http = TextEditingController(text: '${widget.http}');
    _shareIn = TextEditingController();
    _bypassIn = TextEditingController();
    _subUrl = TextEditingController();
    _preferH3 = widget.preferH3;
    _cfBestOn = widget.cfBestOn;
    _cfBestIp = widget.cfBestIp;
    _cfBestMs = widget.cfBestMs;
    _cfBestColo = widget.cfBestColo;
    _fetchEnabled = widget.fetchEnabled;
    _exitVia = normalizeExitVia(widget.exitVia);
    _systemProxy = widget.systemProxy;
    _autoConnect = widget.autoConnect;
    _autoFailover = widget.autoFailover;
    _ruleMode = widget.ruleMode;
    _holdTraffic = widget.holdTraffic;
    _launchAtStartup = false;
    _bypass = List<String>.from(widget.bypass);
    _loadCloudflare();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endpoint != widget.endpoint) _endpoint.text = widget.endpoint;
    if (oldWidget.token != widget.token) _token.text = widget.token;
    if (oldWidget.nodeName != widget.nodeName) _nodeName.text = widget.nodeName;
    if (oldWidget.socks != widget.socks) _socks.text = '${widget.socks}';
    if (oldWidget.http != widget.http) _http.text = '${widget.http}';
    if (oldWidget.preferH3 != widget.preferH3) _preferH3 = widget.preferH3;
    if (oldWidget.cfBestOn != widget.cfBestOn) _cfBestOn = widget.cfBestOn;
    if (oldWidget.cfBestIp != widget.cfBestIp) _cfBestIp = widget.cfBestIp;
    if (oldWidget.cfBestMs != widget.cfBestMs) _cfBestMs = widget.cfBestMs;
    if (oldWidget.cfBestColo != widget.cfBestColo) _cfBestColo = widget.cfBestColo;
    if (oldWidget.fetchEnabled != widget.fetchEnabled) _fetchEnabled = widget.fetchEnabled;
    if (oldWidget.exitVia != widget.exitVia) {
      _exitVia = normalizeExitVia(widget.exitVia);
    }
    if (oldWidget.systemProxy != widget.systemProxy) _systemProxy = widget.systemProxy;
    if (oldWidget.autoConnect != widget.autoConnect) _autoConnect = widget.autoConnect;
    if (oldWidget.autoFailover != widget.autoFailover) _autoFailover = widget.autoFailover;
    if (oldWidget.ruleMode != widget.ruleMode) _ruleMode = widget.ruleMode;
    if (oldWidget.holdTraffic != widget.holdTraffic) _holdTraffic = widget.holdTraffic;
    if (!_listEq(oldWidget.bypass, widget.bypass)) _bypass = List<String>.from(widget.bypass);
  }

  Future<void> _loadCloudflare() async {
    final prefs = await SharedPreferences.getInstance();
    final launch = Autostart.supported ? await Autostart.isEnabled() : false;
    if (!mounted) return;
    _apiToken.text = prefs.getString('cf_api_token') ?? '';
    final savedDomain = prefs.getString('cf_domain') ?? '';
    if (savedDomain.isNotEmpty && savedDomain != 'vpn.example.com') {
      _domain.text = savedDomain;
    }
    _vpsIp.text = prefs.getString('vps_ip') ?? '';
    _subUrl.text = prefs.getString('sub_url') ?? '';
    setState(() {
      _launchAtStartup = launch;
      _subError = prefs.getString('sub_last_error') ?? '';
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    _nodeName.dispose();
    _apiToken.dispose();
    _domain.dispose();
    _vpsIp.dispose();
    _vpsPassword.dispose();
    _socks.dispose();
    _http.dispose();
    _shareIn.dispose();
    _bypassIn.dispose();
    _subUrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _deploy({required bool withVps}) async {
    final socks = int.tryParse(_socks.text.trim());
    final http = int.tryParse(_http.text.trim());
    if (socks == null || http == null || socks == http) {
      _show('两个本地端口要有效，而且不能相同');
      return;
    }
    String? ip;
    if (withVps) {
      ip = publicIpv4(_vpsIp.text);
      if (ip == null) {
        _show('VPS 要填公网 IPv4');
        return;
      }
      if (_vpsPassword.text.isEmpty) {
        _show('先填写 VPS 的 root 密码');
        return;
      }
      if (await _sameHostOtherMode(_domain.text, 'landing')) return;
    }
    setState(() {
      _deploying = true;
      _deployLog
        ..clear()
        ..add(withVps ? '开始：Worker + 服务器' : '开始：只用 Cloudflare');
      _deployStatus = _deployLog.last;
    });
    try {
      var access = newAccessToken();
      if (withVps) {
        access = await VpsSetup().install(
          host: ip!,
          password: _vpsPassword.text,
          token: access,
          requiredPort: 8444,
          onStep: _log,
        );
      }
      final node = await CloudflareSetup().deploy(
        apiToken: _apiToken.text,
        domain: _domain.text,
        accessToken: access,
        landingHost: withVps ? ip! : '',
        landingPort: '8444',
        onStep: _log,
      );
      await _putNode(
        name: _nodeName.text.trim().isEmpty ? suggestedNodeName(node.endpoint, exitVia: withVps ? 'landing' : 'direct') : _nodeName.text.trim(),
        endpoint: node.endpoint,
        token: node.token,
        exitVia: withVps ? 'landing' : 'direct',
        vpsIp: withVps ? ip! : '',
        socks: socks,
        http: http,
      );
      _endpoint.text = node.endpoint;
      _token.text = node.token;
      _exitVia = withVps ? 'landing' : 'direct';
      if (_nodeName.text.trim().isEmpty) {
        _nodeName.text = suggestedNodeName(node.endpoint, exitVia: withVps ? 'landing' : 'direct');
      }
      _log(withVps ? '完成：域名走 Cloudflare，出口走 VPS' : '完成：只用 Cloudflare 直连出口');
      if (!mounted) return;
      await _finishSaved(withVps ? '已接好：域名走 Cloudflare，出口走 VPS' : '已接好：只用 Cloudflare');
    } on CloudflareSetupException catch (err) {
      _log('失败：$err');
      _show(err.message);
    } on VpsSetupException catch (err) {
      _log('失败：$err');
      _show(err.message);
    } catch (_) {
      _log('失败：未知错误');
      _show('部署失败');
    } finally {
      if (mounted) setState(() => _deploying = false);
    }
  }

  Future<void> _deployCdn() async {
    final socks = int.tryParse(_socks.text.trim());
    final http = int.tryParse(_http.text.trim());
    if (socks == null || http == null || socks == http) {
      _show('两个本地端口要有效，而且不能相同');
      return;
    }
    final ip = publicIpv4(_vpsIp.text);
    if (ip == null) {
      _show('VPS 要填公网 IPv4');
      return;
    }
    if (_vpsPassword.text.isEmpty) {
      _show('先填写 VPS 的 root 密码');
      return;
    }
    if (await _sameHostOtherMode(_domain.text, 'cdn')) return;
    setState(() {
      _deploying = true;
      _deployLog
        ..clear()
        ..add('开始：橙云 + 服务器（不走 Worker）');
      _deployStatus = _deployLog.last;
    });
    try {
      final access = await VpsSetup().install(
        host: ip,
        password: _vpsPassword.text,
        token: newAccessToken(),
        requiredPort: 443,
        onStep: _log,
      );
      final node = await CloudflareSetup().bindOrigin(
        apiToken: _apiToken.text,
        domain: _domain.text,
        originIp: ip,
        accessToken: access,
        onStep: _log,
      );
      final name = _nodeName.text.trim().isEmpty ? suggestedNodeName(node.endpoint, exitVia: 'cdn') : _nodeName.text.trim();
      await _putNode(
        name: name,
        endpoint: node.endpoint,
        token: node.token,
        exitVia: 'cdn',
        vpsIp: ip,
        socks: socks,
        http: http,
      );
      _endpoint.text = node.endpoint;
      _token.text = node.token;
      _exitVia = 'cdn';
      if (_nodeName.text.trim().isEmpty) _nodeName.text = name;
      _log('完成：域名橙云回源到 VPS，不计 Worker，优先 HTTP/3');
      if (!mounted) return;
      await _finishSaved('已接好：橙云 + 服务器');
    } on CloudflareSetupException catch (err) {
      _log('失败：$err');
      _show(err.message);
    } on VpsSetupException catch (err) {
      _log('失败：$err');
      _show(err.message);
    } catch (_) {
      _log('失败：未知错误');
      _show('部署失败');
    } finally {
      if (mounted) setState(() => _deploying = false);
    }
  }

  void _log(String step) {
    if (!mounted) return;
    setState(() {
      _deployStatus = step;
      _deployLog.add(step);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _save() async {
    final socks = int.tryParse(_socks.text.trim());
    final http = int.tryParse(_http.text.trim());
    if (socks == null || http == null || socks == http) {
      _show('两个本地端口要有效，而且不能相同');
      return;
    }
    await _persistLocal(socks, http);
    final book = await NodeBook.load();
    final current = book.active;
    if (current != null) {
      current.exitVia = _exitVia;
      await book.save();
    }
    if (!mounted) return;
    await _finishSaved('本机设置已保存');
  }

  Future<void> _finishSaved(String message) async {
    if (widget.onSaved != null) {
      await widget.onSaved!();
      _show(message);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _persistLocal(int socks, int http) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cf_api_token', _apiToken.text.trim());
    await prefs.setString('cf_domain', _domain.text.trim());
    await prefs.setInt('socks', socks);
    await prefs.setInt('http', http);
    await prefs.setBool('prefer_h3', _preferH3);
    await prefs.setBool('cf_best_on', _cfBestOn);
    await prefs.setString('cf_best_ip', _cfBestIp);
    await prefs.setInt('cf_best_ms', _cfBestMs);
    await prefs.setString('cf_best_colo', _cfBestColo);
    await prefs.setBool('fetch_enabled', _fetchEnabled);
    await prefs.setBool('system_proxy', _systemProxy);
    await prefs.setBool('auto_connect', _autoConnect);
    await prefs.setBool('auto_failover', _autoFailover);
    await prefs.setBool('rule_mode', _ruleMode);
    await prefs.setBool('hold_traffic', _holdTraffic);
    await prefs.setString('bypass_hosts', jsonEncode(_bypass));
    if (Autostart.supported) {
      final err = await Autostart.setEnabled(_launchAtStartup);
      if (err != null && mounted) _show(err);
    }
  }

  Future<void> _putNode({
    required String name,
    required String endpoint,
    required String token,
    required String exitVia,
    required String vpsIp,
    required int socks,
    required int http,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _persistLocal(socks, http);
    final book = await NodeBook.load(prefs);
    book.put(name: name, endpoint: endpoint, token: token, exitVia: exitVia, vpsIp: vpsIp);
    if (vpsIp.isNotEmpty) {
      for (final node in book.nodes) {
        if (node.vpsIp == vpsIp) node.token = token;
      }
    }
    await book.save(prefs);
  }

  Future<bool> _sameHostOtherMode(String domain, String via) async {
    final plan = planDomain(domain);
    if (plan == null) return false;
    final book = await NodeBook.load();
    for (final node in book.nodes) {
      if (node.host != plan.hostname || node.exitVia == via) continue;
      final worker = node.exitVia == 'landing' || via == 'landing';
      final cdn = node.exitVia == 'cdn' || via == 'cdn';
      if (worker && cdn) {
        _show('${plan.hostname} 已经是${exitTitle(node.exitVia)}。同一域名不能再绑另一套，请换一个子域名。');
        return true;
      }
    }
    return false;
  }

  Future<void> _import() async {
    final ledger = await ShareBook.load();
    final inspected = await ledger.inspect(_shareIn.text);
    final reject = inspected.rejectMessage;
    if (reject != null) {
      _show(reject);
      return;
    }
    final parsed = inspected.nodes;
    final socks = int.tryParse(_socks.text.trim()) ?? widget.socks;
    final http = int.tryParse(_http.text.trim()) ?? widget.http;
    if (socks == http) {
      _show('两个本地端口要有效，而且不能相同');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await _persistLocal(socks, http);
    final book = await NodeBook.load(prefs);
    for (final node in parsed) {
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
    await book.save(prefs);
    final last = parsed.last;
    _endpoint.text = last.endpoint;
    _token.text = last.token;
    _exitVia = last.exitVia;
    if (last.name.isNotEmpty) _nodeName.text = last.name;
    if (last.vpsIp.isNotEmpty) _vpsIp.text = last.vpsIp;
    if (!mounted) return;
    await _finishSaved(parsed.length == 1 ? '已导入' : '已导入 ${parsed.length} 条节点');
  }

  void _show(String text) {
    if (!mounted) return;
    showTicketSnack(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final titles = [tx('连接', 'Home'), tx('节点', 'Nodes'), tx('导入', 'Import'), tx('搭建', 'Setup'), tx('本机', 'Device')];
    final hints = [
      tx('一键接入当前节点', 'Connect the current node'),
      tx('测试、导入、分享，点一条就能连', 'Test, import, share, then connect'),
      tx('粘贴一条或一批节点配置，会加进列表', 'Paste a node or a batch'),
      tx('三套搭建，以及怎么用', 'Three setup paths'),
      tx('出口、端口，以及不走代理的网址', 'Exit, ports, and bypass sites'),
    ];
    if (widget.panel == 0) {
      return const SizedBox.shrink();
    }
    final size = MediaQuery.sizeOf(context);
    final short = size.height < 680;
    final narrow = size.width < 960;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 20 : 36, short ? 28 : 40, narrow ? 20 : 48, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const YouBadge('SET'),
          const SizedBox(height: 18),
          Text('${titles[widget.panel]}.', style: kDisplay.copyWith(fontSize: short ? 26 : 34)),
          const SizedBox(height: 8),
          const MintLine(width: 120),
          const SizedBox(height: 12),
          Text(hints[widget.panel], style: const TextStyle(color: kMute, height: 1.4, fontSize: 15)),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              decoration: kTicket.copyWith(color: kPaper),
              clipBehavior: Clip.antiAlias,
              child: widget.panel == 1
                  ? NodeBookView(onChanged: widget.onSaved, running: widget.running, connecting: widget.connecting, onConnect: widget.onConnect)
                  : ListView(
                      children: [
                        if (widget.panel == 2) _importPanel(),
                        if (widget.panel == 3) _deployPanel(),
                        if (widget.panel == 4) _localPanel(),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _importPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('把别人分享的 tiaotiaohou1 / tiaotiaohou2 贴进来，会加到节点列表并选用最后一条。', style: TextStyle(color: kMute, height: 1.45, fontSize: 13)),
        const SizedBox(height: 14),
        TicketField(
          label: '节点配置',
          hint: '粘贴 tiaotiaohou1 / tiaotiaohou2 节点配置',
          controller: _shareIn,
          minLines: 5,
          maxLines: 8,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _import,
          icon: const AppIcon('download.svg', color: Colors.white, size: 18),
          label: const Text('导入并使用'),
        ),
        const SizedBox(height: 28),
        const Text('订阅', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 6),
        const Text('填一个返回 tiaotiaohou1 / tiaotiaohou2 的网址。启动后每隔一小时自动更新，手动添加的节点会保留。', style: TextStyle(color: kMute, height: 1.45, fontSize: 13)),
        const SizedBox(height: 14),
        TicketField(label: '订阅地址', hint: 'https://example.com/tiaotiaohou.txt', controller: _subUrl),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _subBusy ? null : _saveSub,
          child: Text(_subBusy ? '正在更新' : '保存并更新'),
        ),
        const SizedBox(height: 10),
        GhostButton(
          label: _subBusy ? '正在重试' : '立即重试',
          onTap: _subBusy ? () {} : () => _retrySub(),
        ),
        if (_subError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_subError, style: const TextStyle(color: Color(0xFFB42318), fontSize: 12, height: 1.4, fontWeight: FontWeight.w700)),
        ],
      ],
    );
  }

  Future<void> _retrySub() async {
    final url = _subUrl.text.trim();
    if (url.isEmpty) {
      _show('先填订阅地址');
      return;
    }
    setState(() => _subBusy = true);
    try {
      final message = await updateSubscription(url);
      if (!mounted) return;
      setState(() => _subError = '');
      await widget.onSaved?.call();
      _show(message);
    } on SubscriptionException catch (err) {
      setState(() => _subError = err.message);
      _show(err.message);
    } catch (_) {
      setState(() => _subError = '订阅更新失败');
      _show('订阅更新失败');
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  Future<void> _saveSub() async {
    final url = _subUrl.text.trim();
    if (url.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('sub_url');
      _show('已清空订阅地址');
      return;
    }
    setState(() => _subBusy = true);
    try {
      final message = await updateSubscription(url);
      if (!mounted) return;
      await widget.onSaved?.call();
      _show(message);
    } on SubscriptionException catch (err) {
      _show(err.message);
    } catch (_) {
      _show('订阅更新失败');
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  Widget _deployPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            InkChip(label: '使用教程', selected: _setupTab == 0, onTap: _deploying ? null : () => setState(() => _setupTab = 0)),
            InkChip(label: '只用 Cloudflare', selected: _setupTab == 1, onTap: _deploying ? null : () => setState(() => _setupTab = 1)),
            InkChip(label: 'Worker + 服务器', selected: _setupTab == 2, onTap: _deploying ? null : () => setState(() => _setupTab = 2)),
            InkChip(label: '橙云 + 服务器', selected: _setupTab == 3, onTap: _deploying ? null : () => setState(() => _setupTab = 3)),
          ],
        ),
        const SizedBox(height: 18),
        if (_setupTab == 0) _guide(),
        if (_setupTab == 1) _cfOnlyForm(),
        if (_setupTab == 2) _cfVpsForm(),
        if (_setupTab == 3) _cdnForm(),
        if (_setupTab != 0) ...[
          const SizedBox(height: 16),
          _logBox(),
        ],
      ],
    );
  }

  Widget _cfFields() {
    return Column(
      children: [
        TicketField(
          label: '节点名称',
          hint: '例如 家里、公司、备用线路，可随便填',
          controller: _nodeName,
        ),
        const SizedBox(height: 16),
        TicketField(
          label: 'Cloudflare API 令牌',
          controller: _apiToken,
          obscure: _obscureApi,
          suffix: IconButton(
            onPressed: () => setState(() => _obscureApi = !_obscureApi),
            icon: AppIcon(_obscureApi ? 'eye-off.svg' : 'eye.svg', color: kMute),
          ),
        ),
        const SizedBox(height: 16),
        TicketField(
          label: '你的域名',
          hint: 'example.com 或 my.example.com',
          controller: _domain,
        ),
      ],
    );
  }

  Widget _guide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选一套再搭', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
        const SizedBox(height: 4),
        const Text('有服务器就选橙云 + 服务器：不计 Worker，网页优先 HTTP/3，游戏也能开。没有服务器才用第一套。', style: TextStyle(color: kMute, height: 1.45, fontSize: 13)),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              _guidePick(
                title: '橙云 + 服务器',
                body: '域名走橙云，回源到你的 VPS。不创建 Worker。填令牌、域名、公网 IP 和 root 密码。',
                via: 'cdn',
                udp: true,
                recommended: true,
                action: '去搭建',
                onTap: () => setState(() => _setupTab = 3),
              ),
              _guidePick(
                title: 'Worker + 服务器',
                body: '网页先到 Worker，再从 VPS 出去。橙云回源不稳时用这套。会占用 Worker 请求额度。',
                via: 'landing',
                udp: true,
                action: '去搭建',
                onTap: () => setState(() => _setupTab = 2),
              ),
              _guidePick(
                title: '只用 Cloudflare',
                body: '只有域名，没有自己的服务器。普通网站可以打开。还有网站进不去时，到「本机」打开「打开打不开的网站」。游戏不行。',
                via: 'direct',
                udp: false,
                action: '去搭建',
                onTap: () => setState(() => _setupTab = 1),
              ),
            ];
            if (constraints.maxWidth < 520) {
              return Column(
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    cards[i],
                  ],
                ],
              );
            }
            final rows = <Widget>[];
            for (var i = 0; i < cards.length; i += 2) {
              final right = i + 1 < cards.length ? cards[i + 1] : null;
              rows.add(
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: cards[i]),
                      const SizedBox(width: 12),
                      Expanded(child: right ?? const SizedBox.shrink()),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  rows[i],
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 22),
        const Text('动手前', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
        const SizedBox(height: 12),
        _guideStep('1', '域名先加进账号', '在 Cloudflare 里能看到这个域名。填 example.com 会用 rsq.example.com；填了子域名就用你写的那个。'),
        _guideStep('2', '做一个 API 令牌', '控制台右上角头像 → My Profile → API Tokens → Create Token，选 Full account and zone access。只显示一次，填在这里，不要发到公开场合。'),
        _guideStep('3', '同一台机器可以两套一起用', 'Worker 连服务器的 8444（TCP，游戏 UDP 也是 8444）。橙云回源用 443。两个端口互不占用。请用两个不同域名：同一个域名不能既绑 Worker，又橙云回源。第二套会沿用这台机器上已有的令牌。'),
        const SizedBox(height: 10),
        const Text('搭完就用', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
        const SizedBox(height: 12),
        _guideStep('4', '看日志，成功再连', '切到上面对应标签，填完点搭建。黑框走到「完成」才算好。然后回「连接」，点「开始连接」。'),
        _guideStep('5', '浏览器和游戏分开', '「本机」打开「连接后设置系统代理」，浏览器就会走跳跳猴。游戏不走系统代理，代理类型选 SOCKS5，地址 127.0.0.1，端口 1080。'),
        _guideStep('6', '节点可以有很多条', '每次搭建都是新加一条，不覆盖旧的。节点页可以改名、测试、分享。别人把配置贴进「导入」，或者在导入页填订阅地址。'),
        const SizedBox(height: 10),
        const Text('搭不上或连不上', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
        const SizedBox(height: 12),
        _guideNote('查找域名失败：令牌权限不够，或域名不在这个账号里。'),
        _guideNote('登录 VPS 失败：本机能连上 22，用户是 root，密码正确。'),
        _guideNote('橙云节点检查失败：安全组没放行 443，或 443 已被别的程序占用。SSL 保持 Full，不要改成 Full (strict)。'),
        _guideNote('有些网站进不去：没有服务器时，到「本机」打开「打开打不开的网站」，然后把浏览器关掉再开。有服务器也可以换成带服务器的两套。'),
        _guideNote('Worker 突然连不上：大约每天 10 万次请求。到「本机」跑一次诊断能看到今天用量。'),
        _guideNote('重连时浏览器会先直连，恢复后代理自动挂回。多条节点时会自动换一条能用的。'),
      ],
    );
  }

  Widget _guidePick({
    required String title,
    required String body,
    required String via,
    required bool udp,
    required String action,
    required VoidCallback onTap,
    bool recommended = false,
  }) {
    return Material(
      color: recommended ? const Color(0xFFF4FBE8) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: kInk, width: recommended ? 2 : 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: kInk))),
                if (recommended) const YouBadge('荐'),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: kMute, height: 1.4, fontSize: 12)),
            const SizedBox(height: 10),
            SupportStrip(exitVia: via, udp: udp),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: onTap, child: Text(action))),
          ],
        ),
      ),
    );
  }

  Widget _guideStep(String n, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            color: kInk,
            child: Text(n, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: kInk)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(color: kMute, height: 1.45, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _guideNote(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 7, height: 7, margin: const EdgeInsets.only(top: 6), color: kMint),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: kMute, height: 1.45, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _cfOnlyForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('只部署 Cloudflare Worker。客户端连你的域名，出口是 Cloudflare。', style: TextStyle(color: kMute, height: 1.45)),
        const SizedBox(height: 16),
        _cfFields(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _deploying ? null : () => _deploy(withVps: false),
          icon: const AppIcon('cloud.svg', color: Colors.white, size: 18),
          label: Text(_deploying ? '正在搭建' : '搭建 Cloudflare'),
        ),
      ],
    );
  }

  Widget _cfVpsForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Worker 从 Cloudflare 连到这台 VPS 的 8444。同一台机器还可以再搭橙云，那套用 443，不会抢这个端口。', style: TextStyle(color: kMute, height: 1.45)),
        const SizedBox(height: 16),
        _cfFields(),
        const SizedBox(height: 16),
        _vpsFields(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _deploying ? null : () => _deploy(withVps: true),
          icon: const AppIcon('server.svg', color: Colors.white, size: 18),
          label: Text(_deploying ? '正在搭建' : '搭建 Worker + 服务器'),
        ),
      ],
    );
  }

  Widget _cdnForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('橙云回源到这台 VPS 的 443，不部署 Worker。和 Worker 那套的 8444 可以同时开，请换一个域名。', style: TextStyle(color: kMute, height: 1.45)),
        const SizedBox(height: 16),
        _cfFields(),
        const SizedBox(height: 16),
        _vpsFields(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _deploying ? null : _deployCdn,
          icon: const AppIcon('cloud.svg', color: Colors.white, size: 18),
          label: Text(_deploying ? '正在搭建' : '搭建橙云 + 服务器'),
        ),
      ],
    );
  }

  Widget _vpsFields() {
    return Column(
      children: [
        TicketField(label: 'VPS 公网 IP', hint: '例如 203.0.113.10', controller: _vpsIp),
        const SizedBox(height: 16),
        TicketField(
          label: 'VPS root 密码',
          controller: _vpsPassword,
          obscure: _obscureVps,
          suffix: IconButton(
            onPressed: () => setState(() => _obscureVps = !_obscureVps),
            icon: AppIcon(_obscureVps ? 'eye-off.svg' : 'eye.svg', color: kMute),
          ),
        ),
      ],
    );
  }

  Widget _logBox() {
    return Container(
      width: double.infinity,
      height: 168,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: kInk,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kInk, width: 1.4),
      ),
      child: _deployLog.isEmpty
          ? const Text('搭建日志会显示在这里', style: TextStyle(color: Color(0x88B7F27A), fontSize: 12))
          : ListView(
              controller: _logScroll,
              children: [
                for (final line in _deployLog)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(line, style: const TextStyle(color: kMint, fontSize: 12, height: 1.35)),
                  ),
              ],
            ),
    );
  }

  Widget _localPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: TicketField(label: 'SOCKS 端口', controller: _socks, keyboardType: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(child: TicketField(label: 'HTTP 端口', controller: _http, keyboardType: TextInputType.number)),
          ],
        ),
        const SizedBox(height: 20),
        const Text('当前节点出口', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
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
        const SizedBox(height: 8),
        Text(exitHint(_exitVia), style: const TextStyle(color: kMute, fontSize: 12, height: 1.4)),
        const SizedBox(height: 20),
        _switchRow(tx('优先走更快线路', 'Faster route'), _preferH3, (value) => setState(() => _preferH3 = value), icon: 'power.svg', hint: tx('不通就自动换，看视频也会自己选', 'Switch if a route fails')),
        _switchRow(tx('Cloudflare 优选 IP', 'Best Cloudflare IP'), _cfBestOn, (value) => setState(() => _cfBestOn = value), icon: 'cloud.svg', hint: tx('晚上这条路堵了就换一个', 'If this address dies at night, try another')),
        if (_cfBestOn) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 24),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _cfPicking
                        ? tx('正在扫描 Cloudflare 节点…', 'Scanning Cloudflare…')
                        : (_cfBestIp.isEmpty
                            ? tx('下次连接时自动扫描', 'Scans on the next connect')
                            : '${tx('当前', 'Now')} ${_cfBestIp}${_cfBestColo.isEmpty ? '' : ' · $_cfBestColo'}${_cfBestMs > 0 ? ' · ${_cfBestMs}ms' : ''}'),
                    style: const TextStyle(color: kMute, fontSize: 12, height: 1.4),
                  ),
                ),
                TextButton(
                  onPressed: _cfPicking ? null : () => _pickBestIpNow(),
                  child: Text(_cfPicking ? tx('扫描中', 'Scanning') : tx('重新优选', 'Rescan')),
                ),
                TextButton(
                  onPressed: _cfPicking || _cfBestIp.isEmpty ? null : () => _pickBestIpNow(skip: {_cfBestIp}),
                  child: Text(tx('换一个', 'Another')),
                ),
              ],
            ),
          ),
        ],
        _switchRow(tx('打开打不开的网站', 'Open more sites'), _fetchEnabled, (value) => unawaited(_setFetch(value)), icon: 'globe.svg', hint: tx('没服务器时再开，改完重启浏览器', 'Turn on without your own server')),
        if (!Platform.isAndroid) _switchRow(tx('连接后设置系统代理', 'System proxy'), _systemProxy, (value) => setState(() => _systemProxy = value), icon: 'settings.svg', hint: tx('浏览器跟着走', 'Browser follows')),
        _switchRow(tx('启动后自动连接', 'Connect on launch'), _autoConnect, (value) => setState(() => _autoConnect = value), icon: 'link.svg', hint: tx('打开软件就连上', 'Connect when the app opens')),
        _switchRow(tx('国内网站直连', 'China sites direct'), _ruleMode, (value) => setState(() => _ruleMode = value), icon: 'cloud.svg', hint: tx('百度、淘宝不走代理', 'Baidu and Taobao stay direct')),
        _switchRow(tx('掉线自动换节点', 'Switch node if down'), _autoFailover, (value) => setState(() => _autoFailover = value), icon: 'share-2.svg', hint: tx('这条不行就换下一条', 'Try the next node')),
        _switchRow(tx('断了先拦住', 'Hold if dropped'), _holdTraffic, (value) => setState(() => _holdTraffic = value), icon: 'shield.svg', hint: tx('掉线不走真实网络', 'Do not leak when down')),
        if (Autostart.supported) _switchRow(tx('开机自启', 'Open at login'), _launchAtStartup, (value) => setState(() => _launchAtStartup = value), icon: 'key-round.svg', hint: tx('开机静默连上，换网也会恢复', 'Connect quietly at startup')),
        const SizedBox(height: 6),
        Text(tx('不走代理的网址', 'Sites that skip the proxy'), style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 6),
        const Text('填域名即可，子域名也会直连。例如 baidu.com、www.bilibili.com。', style: TextStyle(color: kMute, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TicketField(
                label: '添加网址',
                hint: '例如 baidu.com',
                controller: _bypassIn,
                onChanged: (_) {},
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: _addBypass, child: const Text('添加')),
          ],
        ),
        if (_bypass.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final host in _bypass)
                InputChip(
                  label: Text(host, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  onDeleted: () => setState(() => _bypass.remove(host)),
                  deleteIconColor: kInk,
                  side: const BorderSide(color: kInk, width: 1.2),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        const Text('诊断', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 6),
        const Text('检查节点、本地代理和当前出口 IP，方便排查连不上的问题。', style: TextStyle(color: kMute, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton(
              onPressed: _diagBusy ? null : _runDiagnostics,
              child: Text(_diagBusy ? '诊断中' : '开始诊断'),
            ),
            const SizedBox(width: 10),
            if (_diagText.isNotEmpty) GhostButton(label: '复制结果', onTap: _copyDiagnostics),
          ],
        ),
        if (_diagText.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: kInk,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kInk, width: 1.4),
            ),
            child: Text(_diagText, style: const TextStyle(color: kMint, fontSize: 12, height: 1.4)),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: Text(tx('保存', 'Save'))),
      ],
    );
  }

  Future<void> _runDiagnostics() async {
    setState(() => _diagBusy = true);
    try {
      final report = await runDiagnostics(
        endpoint: widget.endpoint,
        token: widget.token,
        exitVia: _exitVia,
        vpsIp: widget.vpsIp,
        socks: int.tryParse(_socks.text.trim()) ?? widget.socks,
        http: int.tryParse(_http.text.trim()) ?? widget.http,
        running: widget.running,
        recentLog: widget.recentLog,
      );
      if (!mounted) return;
      setState(() => _diagText = report.text);
      _show(report.summary);
    } finally {
      if (mounted) setState(() => _diagBusy = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    if (_diagText.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _diagText));
    _show('诊断结果已复制');
  }

  void _addBypass() {
    final host = normalizeBypassHost(_bypassIn.text);
    if (host == null) {
      _show('网址要像 baidu.com 或 https://www.example.com');
      return;
    }
    if (_bypass.contains(host)) {
      _show('已经加过了');
      return;
    }
    setState(() {
      _bypass.add(host);
      _bypassIn.clear();
    });
  }

  Future<void> _pickBestIpNow({Set<String> skip = const {}}) async {
    final host = Uri.tryParse(_endpoint.text.trim())?.host ?? '';
    if (!usesCloudflarePath(_exitVia, host)) {
      _show('当前出口不是 Cloudflare，不用优选 IP');
      return;
    }
    setState(() => _cfPicking = true);
    try {
      final pick = await pickCloudflareIp(host: host, token: _token.text.trim(), skip: skip);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('cf_best_on', true);
      await prefs.setString('cf_best_ip', pick.ip);
      await prefs.setInt('cf_best_ms', pick.ms);
      await prefs.setString('cf_best_colo', pick.colo);
      await prefs.setString('cf_best_host', host);
      await prefs.setInt('cf_best_at', DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      setState(() {
        _cfBestOn = true;
        _cfBestIp = pick.ip;
        _cfBestMs = pick.ms;
        _cfBestColo = pick.colo;
      });
      _show('已优选 ${pick.label}');
      await widget.onSaved?.call();
    } catch (err) {
      if (mounted) _show('$err');
    } finally {
      if (mounted) setState(() => _cfPicking = false);
    }
  }

  Future<void> _setFetch(bool value) async {
    final ok = await showTicketDialog<bool>(
      context,
      (context) => TicketSheet(
        kicker: value ? 'ON' : 'OFF',
        title: value ? '打开打不开的网站？' : '关掉这个功能？',
        child: Text(
          value ? '有的网站现在进不去。打开后就能进。\n\n改完请把浏览器关掉，再开一次。' : '关掉以后，那些网站可能又进不去了。',
          style: const TextStyle(color: kMute, height: 1.45, fontSize: 14),
        ),
        actions: [
          GhostButton(label: '先不用', onTap: () => Navigator.pop(context, false)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(value ? '打开' : '关掉')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _fetchEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fetch_enabled', value);
    String? err;
    try {
      err = RsqCore.open().setFetch(value);
    } catch (caught) {
      err = '$caught';
    }
    if (!mounted) return;
    if (err != null) {
      setState(() => _fetchEnabled = !value);
      await prefs.setBool('fetch_enabled', !value);
      _show(err);
      return;
    }
    await widget.onSaved?.call();
    if (!mounted) return;
    _show(value ? '已打开。请把浏览器关掉再开一次。' : '已关掉。');
  }

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged, {String icon = 'settings.svg', String hint = ''}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          AppIcon(icon, size: 16),
          const SizedBox(width: 8),
          SizedBox(
            width: 148,
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 14)),
          ),
          Expanded(
            child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMute, fontSize: 12)),
          ),
          InkSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

List<String> _readBypass(SharedPreferences prefs) {
  final raw = prefs.getString('bypass_hosts');
  if (raw == null || raw.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    final out = <String>[];
    for (final item in decoded) {
      final host = normalizeBypassHost('$item');
      if (host != null && !out.contains(host)) out.add(host);
    }
    return out;
  } catch (_) {
    return [];
  }
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

String protocolLabel(String mode) {
  if (mode == 'vps') return '直连 VPS';
  const names = {'h3': 'HTTP/3', 'h2': 'HTTP/2', 'h1': 'HTTP/1', 'ws': 'WebSocket'};
  if (mode.startsWith('auto-')) {
    return '自动 ${names[mode.substring(5)] ?? 'HTTP/2'}';
  }
  final parts = mode.split('+').where(names.containsKey).map((part) => names[part]!).toList();
  if (parts.isEmpty) return 'HTTP/2';
  return parts.join(' + ');
}

String _kb(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}
