/// 不走代理的主机名：支持域名、子域名、IPv4。
String? normalizeBypassHost(String input) {
  var text = input.trim().toLowerCase();
  if (text.isEmpty || text.length > 253) return null;
  if (text.startsWith('https://')) {
    text = text.substring('https://'.length);
  } else if (text.startsWith('http://')) {
    text = text.substring('http://'.length);
  }
  final slash = text.indexOf('/');
  if (slash >= 0) text = text.substring(0, slash);
  if (text.startsWith('*.')) text = text.substring(2);
  final colon = text.lastIndexOf(':');
  if (colon > 0) {
    final port = text.substring(colon + 1);
    if (int.tryParse(port) != null) text = text.substring(0, colon);
  }
  text = text.replaceAll('[', '').replaceAll(']', '');
  if (text.isEmpty || text.contains('/') || text.contains(' ') || text.contains('@')) {
    return null;
  }
  if (!text.contains('.') && !_isIpv4(text)) return null;
  return text;
}

bool hostBypasses(String host, Iterable<String> rules) {
  final h = host.trim().toLowerCase().replaceAll('[', '').replaceAll(']', '');
  for (final rule in rules) {
    if (h == rule || h.endsWith('.$rule')) return true;
  }
  return false;
}

bool _isIpv4(String text) {
  final parts = text.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}
