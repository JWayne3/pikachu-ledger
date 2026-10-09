import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

abstract final class TapSoundService {
  static AudioPool? _recordPool;
  static AudioPool? _selectionPool;
  static Future<void>? _initializing;

  static final _audioContext = AudioContext(
    android: AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  static Future<void> initialize() => _initializing ??= _loadPools();

  static Future<void> _loadPools() async {
    AudioPool? recordPool;
    try {
      recordPool = await AudioPool.create(
        source: AssetSource('sounds/record_ding.wav'),
        minPlayers: 1,
        maxPlayers: 2,
        audioContext: _audioContext,
      );
      final selectionPool = await AudioPool.create(
        source: AssetSource('sounds/selection_ding.wav'),
        minPlayers: 1,
        maxPlayers: 2,
        audioContext: _audioContext,
      );
      _recordPool = recordPool;
      _selectionPool = selectionPool;
    } catch (_) {
      await recordPool?.dispose();
      _recordPool = null;
      _selectionPool = null;
    }
  }

  static void playRecordDing() => unawaited(_playDing(record: true));

  static void playSelectionDing() => unawaited(_playDing(record: false));

  static Future<void> _playDing({required bool record}) async {
    try {
      await initialize();
      final pool = record ? _recordPool : _selectionPool;
      if (pool == null) {
        await SystemSound.play(SystemSoundType.click);
        return;
      }
      await pool.start(volume: record ? 0.72 : 0.48);
    } catch (_) {
      try {
        await SystemSound.play(SystemSoundType.click);
      } catch (_) {
        // Keep audio playback failures from interrupting normal app actions.
      }
    }
  }
}
