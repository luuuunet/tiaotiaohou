import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

const kInk = Color(0xFF111111);
const kMute = Color(0xFF6B6B6B);
const kPaper = Color(0xFFF7F6F1);
const kMint = Color(0xFFB7F27A);
const kGold = Color(0xFFF4C63A);
const kLine = Color(0xFF111111);
const kDot = Color(0xD0C9C6BC);

const BoxDecoration kTicket = BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.all(Radius.circular(22)),
  border: Border.fromBorderSide(BorderSide(color: kInk, width: 1.4)),
);

TextStyle get kDisplay => const TextStyle(
      color: kInk,
      fontSize: 40,
      fontWeight: FontWeight.w800,
      height: 1.08,
      letterSpacing: -1.4,
    );

class DotGrid extends StatelessWidget {
  const DotGrid({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DotPainter(),
      child: child,
    );
  }
}

class _DotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = kDot;
    const step = 18.0;
    const r = 1.15;
    for (var y = 10.0; y < size.height; y += step) {
      for (var x = 10.0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class YouBadge extends StatelessWidget {
  const YouBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      color: kInk,
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2),
      ),
    );
  }
}

class MintLine extends StatelessWidget {
  const MintLine({super.key, this.width = 168});
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(width: width, height: 7, color: kMint);
  }
}

class TicketShell extends StatelessWidget {
  const TicketShell({super.key, required this.child, required this.stub, this.onTap, this.height = 210});

  final Widget child;
  final Widget stub;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          height: height,
          decoration: kTicket,
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(26, 22, 18, 20), child: child)),
              SizedBox(width: 14, child: CustomPaint(painter: _DashPainter())),
              SizedBox(width: 128, child: stub),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kInk
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const dash = 5.0;
    const gap = 5.0;
    var y = 18.0;
    while (y < size.height - 18) {
      canvas.drawLine(Offset(0, y), Offset(0, y + dash), paint);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GoldStub extends StatelessWidget {
  const GoldStub({super.key, required this.kicker, required this.big, required this.foot});

  final String kicker;
  final String big;
  final String foot;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kGold,
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppIcon('power.svg', size: 22),
          const SizedBox(height: 8),
          Text(kicker, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: kInk)),
          const SizedBox(height: 6),
          Text(big, textAlign: TextAlign.center, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, height: 1, color: kInk)),
          const SizedBox(height: 8),
          Text(foot, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kInk, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 20, this.color = kInk});

  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/$name',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

class TicketSheet extends StatelessWidget {
  const TicketSheet({
    super.key,
    required this.title,
    required this.child,
    this.kicker = 'SET',
    this.actions = const [],
    this.width = 460,
  });

  final String kicker;
  final String title;
  final Widget child;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
        decoration: kTicket.copyWith(borderRadius: const BorderRadius.all(Radius.circular(18))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            YouBadge(kicker),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w800, height: 1.1)),
            const SizedBox(height: 8),
            const MintLine(width: 88),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
              child: SingleChildScrollView(child: child),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: kInk, width: 1.2),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(label, style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ),
      ),
    );
  }
}

RoundedRectangleBorder get kMenuShape => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: kInk, width: 1.3),
    );

OutlineInputBorder get kFieldBorder => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: kInk, width: 1.2),
    );

ThemeData ticketTheme() {
  final scheme = const ColorScheme.light(
    primary: kInk,
    onPrimary: Colors.white,
    secondary: kMint,
    onSecondary: kInk,
    tertiary: kGold,
    onTertiary: kInk,
    error: Color(0xFFB42318),
    onError: Colors.white,
    surface: Colors.white,
    onSurface: kInk,
    onSurfaceVariant: kMute,
    outline: kInk,
    outlineVariant: kInk,
    surfaceTint: Colors.transparent,
    primaryContainer: kMint,
    onPrimaryContainer: kInk,
    secondaryContainer: kGold,
    onSecondaryContainer: kInk,
    inverseSurface: kInk,
    onInverseSurface: kPaper,
    inversePrimary: kMint,
    scrim: Color(0x66111111),
    shadow: Color(0x22000000),
  ).copyWith(
    surfaceContainer: Colors.white,
    surfaceContainerHigh: Colors.white,
    surfaceContainerHighest: kPaper,
    surfaceContainerLow: Colors.white,
    surfaceContainerLowest: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: kPaper,
    canvasColor: Colors.white,
    cardColor: Colors.white,
    dividerColor: kInk,
    splashColor: const Color(0x22B7F27A),
    highlightColor: const Color(0x14B7F27A),
    colorScheme: scheme,
    iconTheme: const IconThemeData(color: kInk),
    iconButtonTheme: const IconButtonThemeData(style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(kInk))),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kInk, textStyle: const TextStyle(fontWeight: FontWeight.w800)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kInk,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF3A3A3A),
        disabledForegroundColor: Colors.white70,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kInk,
        side: const BorderSide(color: kInk, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      hintStyle: const TextStyle(color: kMute, fontWeight: FontWeight.w500, fontSize: 13),
      labelStyle: const TextStyle(color: kInk, fontWeight: FontWeight.w800),
      floatingLabelStyle: const TextStyle(color: kInk, fontWeight: FontWeight.w800),
      border: kFieldBorder,
      enabledBorder: kFieldBorder,
      focusedBorder: kFieldBorder.copyWith(borderSide: const BorderSide(color: kInk, width: 1.7)),
      errorBorder: kFieldBorder.copyWith(borderSide: const BorderSide(color: Color(0xFFB42318), width: 1.4)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      barrierColor: const Color(0x66111111),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: kInk, width: 1.4),
      ),
      titleTextStyle: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 20),
      contentTextStyle: const TextStyle(color: kMute, height: 1.45, fontSize: 14),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      position: PopupMenuPosition.under,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      textStyle: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 13),
      labelTextStyle: const WidgetStatePropertyAll(TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 13)),
      shape: kMenuShape,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(kMenuShape),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kInk,
      contentTextStyle: const TextStyle(color: kMint, fontWeight: FontWeight.w700, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kInk, width: 1.2)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kInk, circularTrackColor: Color(0x22000000)),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(kInk),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      trackBorderColor: WidgetStateProperty.all(Colors.transparent),
      thickness: WidgetStateProperty.all(4),
      radius: const Radius.circular(8),
      mainAxisMargin: 6,
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.all(kInk)),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? kInk : Colors.white),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: const BorderSide(color: kInk, width: 1.4),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) => kInk),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? kMint : Colors.white),
      trackOutlineColor: WidgetStateProperty.all(kInk),
      trackOutlineWidth: WidgetStateProperty.all(1.3),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: kInk,
      textColor: kInk,
      titleTextStyle: TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 14),
      subtitleTextStyle: TextStyle(color: kMute, fontSize: 12, height: 1.35),
    ),
  );
}

Future<T?> showTicketDialog<T>(BuildContext context, WidgetBuilder builder) {
  return showDialog<T>(
    context: context,
    barrierColor: const Color(0x66111111),
    builder: builder,
  );
}

void showTicketSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Plays connecting.gif frame by frame. A color filter on Image.asset
/// freezes the GIF on the first frame.
class ConnectMark extends StatefulWidget {
  const ConnectMark({super.key, this.color, this.size = 18});

  final Color? color;
  final double size;

  @override
  State<ConnectMark> createState() => _ConnectMarkState();
}

class _ConnectMarkState extends State<ConnectMark> {
  static const _asset = 'assets/icons/connecting.gif';
  static Future<List<_GifFrame>>? _shared;

  List<_GifFrame> _frames = const [];
  var _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _shared ??= _decode();
    _shared!.then((frames) {
      if (!mounted || frames.isEmpty) return;
      setState(() => _frames = frames);
      _schedule();
    });
  }

  static Future<List<_GifFrame>> _decode() async {
    final data = await rootBundle.load(_asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: 96, targetHeight: 96);
    final frames = <_GifFrame>[];
    for (var i = 0; i < codec.frameCount; i++) {
      final next = await codec.getNextFrame();
      final ms = next.duration.inMilliseconds;
      frames.add(_GifFrame(next.image, ms <= 0 ? 20 : ms));
    }
    codec.dispose();
    return frames;
  }

  void _schedule() {
    if (_frames.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: _frames[_index].ms), () {
      if (!mounted || _frames.isEmpty) return;
      setState(() => _index = (_index + 1) % _frames.length);
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.color ?? IconTheme.of(context).color ?? kInk;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: _frames.isEmpty
          ? const SizedBox.shrink()
          : CustomPaint(
              painter: _GifPainter(_frames[_index].image, tint),
              size: Size.square(widget.size),
            ),
    );
  }
}

class _GifFrame {
  const _GifFrame(this.image, this.ms);
  final ui.Image image;
  final int ms;
}

class _GifPainter extends CustomPainter {
  const _GifPainter(this.image, this.tint);

  final ui.Image image;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.mode(tint, BlendMode.srcIn);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GifPainter old) => old.image != image || old.tint != tint;
}

class InkChip extends StatelessWidget {
  const InkChip({super.key, required this.label, this.onTap, this.selected = false, this.icon});

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : kInk;
    return Material(
      color: selected ? kInk : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kInk, width: 1.2),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                IconTheme(data: IconThemeData(color: color, size: 14), child: icon!),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TicketField extends StatelessWidget {
  const TicketField({
    super.key,
    required this.label,
    this.hint,
    this.controller,
    this.obscure = false,
    this.suffix,
    this.minLines,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
    this.dense = false,
  });

  final String label;
  final String? hint;
  final TextEditingController? controller;
  final bool obscure;
  final Widget? suffix;
  final int? minLines;
  final int maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label, style: const TextStyle(color: kInk, fontWeight: FontWeight.w800, fontSize: 12)),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          minLines: minLines,
          maxLines: obscure ? 1 : maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged,
          cursorColor: kInk,
          style: const TextStyle(color: kInk, fontWeight: FontWeight.w600, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            isDense: dense,
            suffixIcon: suffix,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 10 : 14),
          ),
        ),
      ],
    );
  }
}

class InkSwitch extends StatelessWidget {
  const InkSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 46,
        height: 26,
        padding: const EdgeInsets.all(3),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: value ? kMint : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kInk, width: 1.3),
        ),
        child: Container(
          width: 18,
          height: 18,
          decoration: const BoxDecoration(color: kInk, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 桌面滚动条滑块固定短一点，避免内容只多出一点时出现整条黑线。
class TicketScrollBehavior extends MaterialScrollBehavior {
  const TicketScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    switch (getPlatform(context)) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return ShortThumbBar(child: child);
      default:
        return child;
    }
  }
}

class ShortThumbBar extends StatefulWidget {
  const ShortThumbBar({super.key, required this.child});

  final Widget child;

  @override
  State<ShortThumbBar> createState() => _ShortThumbBarState();
}

class _ShortThumbBarState extends State<ShortThumbBar> {
  static const _length = 42.0;
  static const _thick = 4.0;

  double _pixels = 0;
  double _max = 0;
  double _viewport = 0;
  var _scrollable = false;

  void _apply(ScrollMetrics metrics, {required int depth}) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    final max = metrics.maxScrollExtent;
    final next = max > 8;
    if (!next && !_scrollable) return;
    if (next == _scrollable &&
        (_pixels - metrics.pixels).abs() < 0.5 &&
        (_max - max).abs() < 0.5 &&
        (_viewport - metrics.viewportDimension).abs() < 0.5) {
      return;
    }
    setState(() {
      _pixels = metrics.pixels;
      _max = max;
      _viewport = metrics.viewportDimension;
      _scrollable = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = (_viewport - _length - 12).clamp(0.0, double.infinity);
    final t = _max <= 0 ? 0.0 : (_pixels / _max).clamp(0.0, 1.0);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        _apply(n.metrics, depth: n.depth);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          _apply(n.metrics, depth: n.depth);
          return false;
        },
        child: Stack(
          children: [
            widget.child,
            if (_scrollable)
              Positioned(
                right: 4,
                top: 6 + track * t,
                child: IgnorePointer(
                  child: Container(
                    width: _thick,
                    height: _length,
                    decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TicketMenuButton<T> extends StatelessWidget {
  const TicketMenuButton({super.key, required this.items, required this.onSelected, this.tooltip = '更多'});

  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: kMenuShape,
      offset: const Offset(0, 8),
      onSelected: onSelected,
      itemBuilder: (context) => items,
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(right: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kInk, width: 1.15),
        ),
        child: const Text('···', style: TextStyle(color: kInk, fontWeight: FontWeight.w800, height: 1, fontSize: 14)),
      ),
    );
  }
}
