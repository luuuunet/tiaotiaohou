import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面语言。zh 简体，en 英文。
class AppLang extends ChangeNotifier {
  AppLang._();
  static final AppLang I = AppLang._();

  String code = 'zh';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('ui_lang') ?? 'zh';
    code = saved == 'en' ? 'en' : 'zh';
    notifyListeners();
  }

  void setCode(String next) {
    final value = next == 'en' ? 'en' : 'zh';
    if (value == code) return;
    code = value;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) => prefs.setString('ui_lang', code));
  }
}

String tx(String zh, String en) => AppLang.I.code == 'en' ? en : zh;
