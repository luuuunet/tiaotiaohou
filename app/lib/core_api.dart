import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class RsqCore {
  RsqCore._(this._start, this._stop, this._stats, this._lastError, this._setFetch);

  final int Function(Pointer<Utf8>) _start;
  final int Function() _stop;
  final Pointer<Utf8> Function() _stats;
  final Pointer<Utf8> Function() _lastError;
  final int Function(int) _setFetch;

  static RsqCore? _loaded;

  static RsqCore open() {
    final existing = _loaded;
    if (existing != null) return existing;
    final library = _openLibrary();
    final core = RsqCore._(
      library.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('rsq_start'),
      library.lookupFunction<Int32 Function(), int Function()>('rsq_stop'),
      library.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rsq_stats'),
      library.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rsq_last_error'),
      library.lookupFunction<Int32 Function(Int32), int Function(int)>('rsq_set_fetch'),
    );
    _loaded = core;
    return core;
  }

  String? start(String configJson) {
    final ptr = configJson.toNativeUtf8();
    try {
      final code = _start(ptr);
      if (code == 0) return null;
      return _read(_lastError());
    } finally {
      malloc.free(ptr);
    }
  }

  void stop() {
    _stop();
  }

  String? setFetch(bool enabled) {
    final code = _setFetch(enabled ? 1 : 0);
    if (code == 0) return null;
    return _read(_lastError());
  }

  Map<String, dynamic> stats() {
    final raw = _read(_stats());
    if (raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {};
  }

  static String _read(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }
}

DynamicLibrary _openLibrary() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('librsq_core.so');
  }
  final name = Platform.isWindows
      ? 'rsq_core.dll'
      : Platform.isMacOS
          ? 'librsq_core.dylib'
          : 'librsq_core.so';
  final found = _find(name);
  if (found == null) {
    throw ArgumentError('找不到 $name。先在 core 目录执行 cargo build --release。');
  }
  return DynamicLibrary.open(found);
}

String? _find(String name) {
  final roots = <Directory>[File(Platform.resolvedExecutable).parent, Directory.current];
  for (final root in roots) {
    var dir = root;
    for (var i = 0; i < 8; i++) {
      final beside = File('${dir.path}${Platform.pathSeparator}$name');
      if (beside.existsSync()) return beside.path;
      for (final profile in const ['release', 'debug']) {
        final nested = File(
          '${dir.path}${Platform.pathSeparator}core${Platform.pathSeparator}target${Platform.pathSeparator}$profile${Platform.pathSeparator}$name',
        );
        if (nested.existsSync()) return nested.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  return null;
}
