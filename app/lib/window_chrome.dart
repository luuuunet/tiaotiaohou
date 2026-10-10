import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_host.dart';
import 'i18n.dart';
import 'look.dart';

const _host = MethodChannel('dev.rsq/host');

class WindowChrome {
  /// 真正退出前清理系统代理 / 核心（托盘「退出」）。
  static Future<void> Function()? beforeQuit;
}

class WindowShell extends StatelessWidget {
  const WindowShell({super.key, required this.child});

  final Widget child;

  static bool get framed => !Platform.isAndroid && !Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    if (!framed) return child;
    return Container(
      decoration: const BoxDecoration(
        color: kPaper,
        border: Border.fromBorderSide(BorderSide(color: kInk, width: 1.4)),
      ),
      child: Stack(
        children: [
          child,
          const Positioned(top: 0, left: 0, right: 150, height: 42, child: _DragStrip()),
          const Positioned(top: 10, right: 10, child: WindowButtons()),
        ],
      ),
    );
  }
}

class _DragStrip extends StatelessWidget {
  const _DragStrip();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _host.invokeMethod<void>('drag'),
      onDoubleTap: Platform.isMacOS ? null : () => _host.invokeMethod<void>('zoom'),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLang.I,
      builder: (context, _) => Row(
      children: [
        const _LangButton(),
        const SizedBox(width: 8),
        _WinDot(
          fill: Colors.white,
          hover: kMint,
          ink: kInk,
          tooltip: tx('最小化', 'Minimize'),
          onTap: () => _host.invokeMethod<void>('minimize'),
          child: Container(width: 11, height: 2, color: kInk),
        ),
        if (!Platform.isMacOS) ...[
          const SizedBox(width: 8),
          _WinDot(
            fill: Colors.white,
            hover: kGold,
            ink: kInk,
            tooltip: tx('放大', 'Zoom'),
            onTap: () => _host.invokeMethod<void>('zoom'),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(border: Border.all(color: kInk, width: 1.6), borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ],
        const SizedBox(width: 8),
        _WinDot(
          fill: kInk,
          hover: const Color(0xFFE24B4B),
          ink: Colors.white,
          tooltip: tx('关闭', 'Close'),
          onTap: () async {
            if (Platform.isMacOS) {
              await DesktopHost.hideToTray();
              return;
            }
            try {
              await WindowChrome.beforeQuit?.call();
            } catch (_) {}
            await DesktopHost.quit();
          },
          child: CustomPaint(size: const Size(10, 10), painter: _CloseX(Colors.white)),
        ),
      ],
    ),
    );
  }
}

class _LangButton extends StatelessWidget {
  const _LangButton();

  @override
  Widget build(BuildContext context) {
    final en = AppLang.I.code == 'en';
    return Material(
      type: MaterialType.transparency,
      child: PopupMenuButton<String>(
      tooltip: tx('语言', 'Language'),
      padding: EdgeInsets.zero,
      onSelected: AppLang.I.setCode,
      itemBuilder: (context) => [
        PopupMenuItem(value: 'zh', child: Text('简体中文', style: TextStyle(fontWeight: AppLang.I.code == 'zh' ? FontWeight.w800 : FontWeight.w500))),
        PopupMenuItem(value: 'en', child: Text('English', style: TextStyle(fontWeight: AppLang.I.code == 'en' ? FontWeight.w800 : FontWeight.w500))),
      ],
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(side: BorderSide(color: kInk, width: 1.3)),
        child: const SizedBox(
          width: 28,
          height: 28,
          child: Center(child: _LangMark()),
        ),
      ),
    ),
    );
  }
}

class _LangMark extends StatelessWidget {
  const _LangMark();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Text('文', style: TextStyle(color: kInk, fontSize: 13, fontWeight: FontWeight.w900, height: 1)),
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.all(Radius.circular(1.5))),
              child: SizedBox(
                width: 10,
                height: 10,
                child: Center(
                  child: Text('A', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900, height: 1)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WinDot extends StatefulWidget {
  const _WinDot({
    required this.fill,
    required this.hover,
    required this.ink,
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final Color fill;
  final Color hover;
  final Color ink;
  final String tooltip;
  final FutureOr<void> Function() onTap;
  final Widget child;

  @override
  State<_WinDot> createState() => _WinDotState();
}

class _WinDotState extends State<_WinDot> {
  var _over = false;

  @override
  Widget build(BuildContext context) {
    final fill = _over ? widget.hover : widget.fill;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: Material(
          color: fill,
          shape: const CircleBorder(side: BorderSide(color: kInk, width: 1.3)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              unawaited(Future.sync(widget.onTap));
            },
            child: SizedBox(width: 28, height: 28, child: Center(child: widget.child)),
          ),
        ),
      ),
    );
  }
}

class _CloseX extends CustomPainter {
  const _CloseX(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _CloseX oldDelegate) => oldDelegate.color != color;
}
