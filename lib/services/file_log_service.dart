import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/app_logger.dart';

/// Flushes in-memory log entries to a file on external storage.
///
/// Enabled/disabled via the "Save logs to file" setting. Requests
/// [Permission.storage] at enable time on Android ≤12; falls back to the
/// app-private external directory on Android 13+ where that permission is
/// unavailable. Target path (when granted):
///   /storage/emulated/0/Documents/Plezy/logs/plezy.log
///
/// Access on Google TV without a clipboard:
///   adb pull /storage/emulated/0/Documents/Plezy/logs/plezy.log
///   — or browse with any file manager app to Documents/Plezy/logs/
///
/// Rotates to plezy.log.old when the file exceeds 2 MB.
class FileLogService {
  FileLogService._();

  static const _publicLogDir = '/storage/emulated/0/Documents/Plezy/logs';
  static const _logFile = 'plezy.log';
  static const _maxBytes = 2 * 1024 * 1024; // 2 MB

  static bool _enabled = false;
  static Timer? _timer;
  static File? _file;
  static DateTime? _lastFlushedAt;

  static bool get enabled => _enabled;

  /// Called synchronously by [BoolPref.onWrite] when the setting changes.
  static void onEnabledChanged(bool value) {
    _enabled = value;
    if (value) {
      unawaited(_requestPermissionAndStart());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  static Future<void> _requestPermissionAndStart() async {
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        // Permission denied — fall back to app-private external dir
        // (still accessible via ADB: adb pull /sdcard/Android/data/<pkg>/files/Plezy/logs/)
        appLogger.w('Storage permission denied; logs will write to app-private external dir');
      }
    }
    _startTimer();
    await _initAndFlush();
  }

  static void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_flush()));
  }

  static Future<void> _initAndFlush() async {
    _file = await _resolveFile();
    await _flush();
  }

  static Future<File?> _resolveFile() async {
    try {
      // Try public Documents directory first (requires storage permission on Android ≤12,
      // covered by requestLegacyExternalStorage on Android 10).
      if (Platform.isAndroid) {
        final publicDir = Directory(_publicLogDir);
        try {
          await publicDir.create(recursive: true);
          final f = File('${publicDir.path}/$_logFile');
          return f;
        } catch (_) {
          // Fall through to app-private external dir
        }
      }
      // Fallback: app-private external directory (no permission required).
      final base = await getExternalStorageDirectory();
      if (base == null) return null;
      final dir = Directory('${base.path}/Plezy/logs');
      await dir.create(recursive: true);
      return File('${dir.path}/$_logFile');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _flush() async {
    if (!_enabled) return;
    final file = _file ??= await _resolveFile();
    if (file == null) return;

    final allEntries = MemoryLogOutput.getLogs().reversed.toList(); // chronological
    if (allEntries.isEmpty) return;

    final cutoff = _lastFlushedAt;
    final newEntries = cutoff == null
        ? allEntries
        : allEntries.where((e) => e.timestamp.isAfter(cutoff)).toList();
    if (newEntries.isEmpty) return;
    _lastFlushedAt = newEntries.last.timestamp;

    try {
      if (await file.exists() && await file.length() > _maxBytes) {
        final old = File('${file.parent.path}/plezy.log.old');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
        _file = await _resolveFile();
        if (_file == null) return;
      }

      final sink = _file!.openWrite(mode: FileMode.append);
      for (final entry in newEntries) {
        final level = entry.level.name.toUpperCase().padRight(5);
        final ts = entry.timestamp.toIso8601String();
        sink.writeln('$ts $level ${entry.message}');
        if (entry.error != null) sink.writeln('       ERR: ${entry.error}');
        if (entry.stackTrace != null) {
          for (final line in entry.stackTrace.toString().split('\n').take(8)) {
            sink.writeln('       $line');
          }
        }
      }
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  /// Returns the log file path for display in the UI (null if unavailable).
  static Future<String?> logFilePath() async {
    final f = _file ?? await _resolveFile();
    return f?.path;
  }
}
