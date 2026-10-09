import 'package:flutter/material.dart';

/// 从节点名称里认出国家。认不出就返回空。
String? countryCodeOf(String text) {
  final raw = text.trim().toLowerCase();
  if (raw.isEmpty) return null;
  const names = <(String, String)>[
    ('hong kong', 'HK'),
    ('hongkong', 'HK'),
    ('新加坡', 'SG'),
    ('澳大利亚', 'AU'),
    ('加拿大', 'CA'),
    ('马来西亚', 'MY'),
    ('印度尼西亚', 'ID'),
    ('菲律宾', 'PH'),
    ('荷兰', 'NL'),
    ('德国', 'DE'),
    ('法国', 'FR'),
    ('英国', 'GB'),
    ('俄罗斯', 'RU'),
    ('土耳其', 'TR'),
    ('巴西', 'BR'),
    ('越南', 'VN'),
    ('泰国', 'TH'),
    ('印度', 'IN'),
    ('日本', 'JP'),
    ('韩国', 'KR'),
    ('美国', 'US'),
    ('中国', 'CN'),
    ('香港', 'HK'),
    ('澳门', 'MO'),
    ('台湾', 'TW'),
    ('singapore', 'SG'),
    ('australia', 'AU'),
    ('canada', 'CA'),
    ('malaysia', 'MY'),
    ('indonesia', 'ID'),
    ('philippines', 'PH'),
    ('netherlands', 'NL'),
    ('germany', 'DE'),
    ('france', 'FR'),
    ('britain', 'GB'),
    ('england', 'GB'),
    ('russia', 'RU'),
    ('turkey', 'TR'),
    ('brazil', 'BR'),
    ('vietnam', 'VN'),
    ('thailand', 'TH'),
    ('india', 'IN'),
    ('japan', 'JP'),
    ('korea', 'KR'),
    ('america', 'US'),
    ('china', 'CN'),
    ('taiwan', 'TW'),
    ('macau', 'MO'),
    ('macao', 'MO'),
  ];
  for (final item in names) {
    if (raw.contains(item.$1)) return item.$2;
  }
  const codes = ['HK', 'MO', 'TW', 'SG', 'AU', 'CA', 'MY', 'ID', 'PH', 'NL', 'DE', 'FR', 'GB', 'UK', 'RU', 'TR', 'BR', 'VN', 'TH', 'IN', 'JP', 'KR', 'US', 'CN'];
  for (final code in codes) {
    final lower = code.toLowerCase();
    if (RegExp('(^|[^a-z])$lower([^a-z]|\$)').hasMatch(raw)) {
      return code == 'UK' ? 'GB' : code;
    }
  }
  return null;
}

class FlagMark extends StatelessWidget {
  const FlagMark(this.code, {super.key, this.height = 14});

  final String code;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * 1.45,
      height: height,
      child: CustomPaint(painter: _FlagPainter(code.toUpperCase())),
    );
  }
}

class _FlagPainter extends CustomPainter {
  _FlagPainter(this.code);
  final String code;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)));
    _draw(canvas, size);
    canvas.restore();
  }

  void _draw(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    void fill(Color color, Rect rect) => canvas.drawRect(rect, Paint()..color = color);
    void bands(List<Color> colors, {bool vertical = false}) {
      for (var i = 0; i < colors.length; i++) {
        final rect = vertical
            ? Rect.fromLTWH(w * i / colors.length, 0, w / colors.length, h)
            : Rect.fromLTWH(0, h * i / colors.length, w, h / colors.length);
        fill(colors[i], rect);
      }
    }

    switch (code) {
      case 'US':
        for (var i = 0; i < 7; i++) {
          fill(i.isEven ? const Color(0xFFB22234) : Colors.white, Rect.fromLTWH(0, h * i / 7, w, h / 7));
        }
        fill(const Color(0xFF3C3B6E), Rect.fromLTWH(0, 0, w * 0.42, h * 0.54));
      case 'KR':
        fill(Colors.white, Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.28, Paint()..color = const Color(0xFFCD2E3A));
        canvas.drawArc(Rect.fromCircle(center: Offset(w * 0.5, h * 0.5), radius: h * 0.28), 0.2, 3.14, true, Paint()..color = const Color(0xFF0047A0));
      case 'JP':
        fill(Colors.white, Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.28, Paint()..color = const Color(0xFFBC002D));
      case 'CN':
        fill(const Color(0xFFDE2910), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.22, h * 0.32), h * 0.12, Paint()..color = const Color(0xFFFFDE00));
      case 'HK':
        fill(const Color(0xFFDE2910), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.22, Paint()..color = Colors.white);
      case 'TW':
        fill(const Color(0xFFFE0000), Offset.zero & size);
        fill(const Color(0xFF000095), Rect.fromLTWH(0, 0, w * 0.5, h * 0.5));
        canvas.drawCircle(Offset(w * 0.25, h * 0.25), h * 0.1, Paint()..color = Colors.white);
      case 'MO':
        fill(const Color(0xFF00785A), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.5, h * 0.55), h * 0.16, Paint()..color = const Color(0xFFFFDF1E));
      case 'SG':
        bands(const [Color(0xFFEF3340), Colors.white]);
        canvas.drawCircle(Offset(w * 0.22, h * 0.25), h * 0.12, Paint()..color = Colors.white);
      case 'GB':
        fill(const Color(0xFF012169), Offset.zero & size);
        final white = Paint()
          ..color = Colors.white
          ..strokeWidth = h * 0.22;
        canvas.drawLine(Offset.zero, Offset(w, h), white);
        canvas.drawLine(Offset(w, 0), Offset(0, h), white);
        canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h), white..strokeWidth = h * 0.28);
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), white);
        final red = Paint()
          ..color = const Color(0xFFC8102E)
          ..strokeWidth = h * 0.1;
        canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h), red);
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), red);
      case 'DE':
        bands(const [Color(0xFF000000), Color(0xFFDD0000), Color(0xFFFFCE00)]);
      case 'FR':
        bands(const [Color(0xFF0055A4), Colors.white, Color(0xFFEF4135)], vertical: true);
      case 'CA':
        bands(const [Color(0xFFFF0000), Colors.white, Color(0xFFFF0000)], vertical: true);
      case 'AU':
        fill(const Color(0xFF012169), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.28, h * 0.38), h * 0.08, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(w * 0.72, h * 0.62), h * 0.06, Paint()..color = Colors.white);
      case 'NL':
        bands(const [Color(0xFFAE1C28), Colors.white, Color(0xFF21468B)]);
      case 'RU':
        bands(const [Colors.white, Color(0xFF0039A6), Color(0xFFD52B1E)]);
      case 'IN':
        bands(const [Color(0xFFFF9933), Colors.white, Color(0xFF138808)]);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.1, Paint()..color = const Color(0xFF000080)..style = PaintingStyle.stroke..strokeWidth = 1);
      case 'TR':
        fill(const Color(0xFFE30A17), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.42, h * 0.5), h * 0.22, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(w * 0.48, h * 0.5), h * 0.16, Paint()..color = const Color(0xFFE30A17));
      case 'BR':
        fill(const Color(0xFF009C3B), Offset.zero & size);
        final path = Path()
          ..moveTo(w * 0.5, h * 0.12)
          ..lineTo(w * 0.9, h * 0.5)
          ..lineTo(w * 0.5, h * 0.88)
          ..lineTo(w * 0.1, h * 0.5)
          ..close();
        canvas.drawPath(path, Paint()..color = const Color(0xFFFFDF00));
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.16, Paint()..color = const Color(0xFF002776));
      case 'VN':
        fill(const Color(0xFFDA251D), Offset.zero & size);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), h * 0.16, Paint()..color = const Color(0xFFFF0));
      case 'TH':
        bands(const [Color(0xFFA51931), Colors.white, Color(0xFF2D2A4A), Colors.white, Color(0xFFA51931)]);
      case 'MY':
        for (var i = 0; i < 6; i++) {
          fill(i.isEven ? const Color(0xFFCC0001) : Colors.white, Rect.fromLTWH(0, h * i / 6, w, h / 6));
        }
        fill(const Color(0xFF010066), Rect.fromLTWH(0, 0, w * 0.5, h * 0.5));
      case 'ID':
        bands(const [Color(0xFFCE1126), Colors.white]);
      case 'PH':
        bands(const [Color(0xFF0038A8), Color(0xFFCE1126)]);
        final tri = Path()
          ..moveTo(0, 0)
          ..lineTo(w * 0.42, h * 0.5)
          ..lineTo(0, h)
          ..close();
        canvas.drawPath(tri, Paint()..color = Colors.white);
      default:
        fill(const Color(0xFFF4F6F1), Offset.zero & size);
    }
  }

  @override
  bool shouldRepaint(covariant _FlagPainter old) => old.code != code;
}
