import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class TapSoundService {
  static AudioPool? _recordPool;
  static AudioPool? _selectionPool;
  static AudioPool? _uiClickPool;
  static Future<void>? _initializing;

  static final _audioContext = AudioContext(
    android: AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  static Future<void> initialize() {
    return _initializing ??= _loadPools().whenComplete(() {
      _initializing = null;
    });
  }

  static Future<void> _loadPools() async {
    _recordPool ??= await _createPool('sounds/record_ding.wav');
    _selectionPool ??= await _createPool('sounds/selection_ding.wav');
    _uiClickPool ??= await _createPool('sounds/ui_click.wav');
  }

  static Future<AudioPool?> _createPool(String assetPath) async {
    try {
      return await AudioPool.create(
        source: AssetSource(assetPath),
        minPlayers: 1,
        maxPlayers: 2,
        audioContext: _audioContext,
      );
    } catch (error, stackTrace) {
      debugPrint('TapSoundService: failed to load $assetPath: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  static void playRecordDing() => unawaited(_playDing(record: true));

  static void playSelectionDing() => unawaited(_playDing(record: false));

  static void playUiClick() => unawaited(_playUiClick());

  static VoidCallback? withUiClick(VoidCallback? callback) {
    if (callback == null) return null;
    return () {
      playUiClick();
      callback();
    };
  }

  static ValueChanged<T>? withUiClickValue<T>(ValueChanged<T>? callback) {
    if (callback == null) return null;
    return (value) {
      playUiClick();
      callback(value);
    };
  }

  static Future<void> _playUiClick() async {
    try {
      await initialize();
      final pool = _uiClickPool;
      if (pool == null) {
        await SystemSound.play(SystemSoundType.click);
        return;
      }
      await pool.start(volume: 0.7);
    } catch (error) {
      debugPrint('TapSoundService: UI click playback failed: $error');
      await _playSystemClick();
    }
  }

  static Future<void> _playDing({required bool record}) async {
    try {
      await initialize();
      final pool = record ? _recordPool : _selectionPool;
      if (pool == null) {
        await _playSystemClick();
        return;
      }
      await pool.start(volume: record ? 0.72 : 0.48);
    } catch (error) {
      debugPrint('TapSoundService: ding playback failed: $error');
      await _playSystemClick();
    }
  }

  static Future<void> _playSystemClick() async {
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (error) {
      debugPrint('TapSoundService: system click playback failed: $error');
    }
  }
}
