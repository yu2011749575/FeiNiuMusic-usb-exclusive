import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:usb_audio_exclusive/usb_audio_exclusive.dart';

import 'player_engine.dart';

/// [PlayerEngine] 的 USB 独占实现（Android）。
///
/// 播放管线：MediaCodec 解码 → 原始 PCM →（USB DAC：usbdevfs 等时传输
/// bit-perfect 直出 / 无设备：AudioTrack 直通）。**不走服务器转码**——
/// 独占模式的语义就是原始未压缩位流直出。
///
/// 队列语义对齐 just_audio：内部维护条目列表，曲末自动前进并广播
/// currentIndexStream；单曲循环由 [setLoopMode] 驱动。位置/时长按
/// [UsbExclusiveItem.startMs] 平移到曲目相对时间轴。
class UsbExclusiveEngine implements PlayerEngine {
  UsbExclusiveEngine() {
    _eventSub = UsbAudioExclusive.playbackEvents.listen(_onPluginEvent);
  }

  StreamSubscription<ExclusivePlaybackEvent>? _eventSub;

  final List<UsbExclusiveItem> _items = [];
  int _index = 0;
  bool _playing = false;
  // 会话守卫：stop() 后引擎与插件会话脱钩，迟到的插件事件（如死亡解码线程的
  // completed）绝不能再触发 _playCurrent——那会在降级期拉起第二个 usb 会话与
  // 系统流互殴（ECHO-A 爆音根因之一，2026-09-25）。loadQueue/play 重新激活。
  bool _stopped = false;
  EngineProcessingState _processingState = EngineProcessingState.idle;
  EngineLoopMode _loopMode = EngineLoopMode.none;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _hasLoaded = false;

  final StreamController<Duration> _positions =
      StreamController.broadcast();
  final StreamController<Duration?> _durations =
      StreamController.broadcast();
  final StreamController<Duration> _buffered =
      StreamController.broadcast();
  final StreamController<EnginePlaybackState> _states =
      StreamController.broadcast();
  final StreamController<EngineError> _errors =
      StreamController.broadcast();
  final StreamController<int?> _indices =
      StreamController.broadcast();

  void _emitState() {
    _states.add(EnginePlaybackState(
      playing: _playing,
      processingState: _processingState,
    ));
  }

  void _onPluginEvent(ExclusivePlaybackEvent e) {
    // 会话守卫：stop() 之后的事件全部丢弃（见 _stopped 注释）。
    if (_stopped) return;
    final item = (_index >= 0 && _index < _items.length) ? _items[_index] : null;
    final shiftMs = item?.startMs ?? 0;
    final posMs = (e.positionMs - shiftMs).clamp(0, 1 << 40);
    _position = Duration(milliseconds: posMs);
    final rawDur = e.durationMs;
    if (rawDur != null) {
      int d = (item?.endMs != null)
          ? (item!.endMs! - shiftMs)
          : (rawDur - shiftMs);
      if (d < 0) d = rawDur;
      _duration = Duration(milliseconds: d);
      _durations.add(_duration);
    }
    _positions.add(_position);
    _buffered.add(_position);

    switch (e.state) {
      case 'loading':
        _processingState = EngineProcessingState.loading;
        _emitState();
      case 'ready':
        _processingState = EngineProcessingState.ready;
        _emitState();
      case 'playing':
        _playing = true;
        _processingState = EngineProcessingState.ready;
        _emitState();
      case 'paused':
        _playing = false;
        _processingState = EngineProcessingState.ready;
        _emitState();
      case 'completed':
        _onCompleted();
      case 'error':
        _playing = false;
        _processingState = EngineProcessingState.idle;
        _errors.add(EngineError(
          message: e.message ?? 'exclusive playback error',
          index: _index,
        ));
        _emitState();
      default:
        _processingState = EngineProcessingState.idle;
        _emitState();
    }
  }

  void _onCompleted() {
    if (_loopMode == EngineLoopMode.single) {
      _playCurrent();
      return;
    }
    if (_index + 1 < _items.length) {
      _index++;
      _indices.add(_index);
      _playCurrent();
    } else {
      _playing = false;
      _processingState = EngineProcessingState.completed;
      _emitState();
    }
  }

  void _playCurrent({Duration? initialPosition}) {
    final item = _items[_index];
    final startMs = item.startMs + (initialPosition?.inMilliseconds ?? 0);
    _processingState = EngineProcessingState.loading;
    _emitState();
    unawaited(UsbAudioExclusive.play(
      url: item.url,
      headers: item.headers,
      isFile: item.isFile,
      startMs: startMs,
      endMs: item.endMs,
      title: item.title,
    ));
  }

  @override
  EngineKind get kind => EngineKind.usbExclusive;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    await stop();
  }

  @override
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
    bool resumeIfSame = false,
  }) async {
    _stopped = false;
    final newItems = items.cast<UsbExclusiveItem>();
    // 同曲同位重载（队列后台填充/自动扩展换条目表）：只更新内部列表，
    // 不打断当前播放（不重启 _playCurrent），避免"曲子从头重放"。
    if (resumeIfSame &&
        _hasLoaded &&
        _items.isNotEmpty &&
        _index == index &&
        index >= 0 &&
        index < newItems.length &&
        _items[_index].url == newItems[index].url) {
      _items
        ..clear()
        ..addAll(newItems);
      return;
    }
    _items
      ..clear()
      ..addAll(newItems);
    _index = index.clamp(0, (_items.length - 1).clamp(0, 1 << 30));
    if (_items.isEmpty) return;
    _hasLoaded = true;
    _indices.add(_index);
    _playCurrent(initialPosition: initialPosition);
  }

  @override
  Future<void> play() async {
    _stopped = false;
    _playing = true;
    _emitState();
    if (_processingState == EngineProcessingState.idle &&
        _items.isNotEmpty) {
      _playCurrent();
    } else {
      await UsbAudioExclusive.resume();
    }
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _emitState();
    await UsbAudioExclusive.pause();
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _playing = false;
    _processingState = EngineProcessingState.idle;
    _hasLoaded = false;
    await UsbAudioExclusive.stop();
    _emitState();
  }

  @override
  Future<void> seek(Duration position) async {
    final item = _items[_index];
    _position = position;
    _positions.add(_position);
    final fileMs = item.startMs + position.inMilliseconds;
    debugPrint('[UsbExclusiveEngine] seek trackPos=$position fileMs=$fileMs');
    await UsbAudioExclusive.seek(fileMs);
  }

  @override
  Future<void> seekToNext() async {
    if (_index + 1 < _items.length) {
      await skipToIndex(_index + 1);
    }
  }

  @override
  Future<void> seekToPrevious() async {
    if (_index > 0) {
      await skipToIndex(_index - 1);
    }
  }

  @override
  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= _items.length) return;
    _index = index;
    _indices.add(_index);
    _playCurrent();
  }

  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    _loopMode = mode;
  }

  @override
  Future<void> setVolume(double volume) async {
    // 独占后端也支持软件音量（= app 音量 × 手机媒体音量比，双满格才
    // bit-perfect；调低=线性衰减）。手机音量键由原生层轮询系统音量接入。
    await UsbAudioExclusive.setVolume(volume.clamp(0, 1));
  }

  @override
  Future<void> setSpeed(double speed) async {
    // 独占管线固定原速（变速需重采样，违背 bit-perfect）。
  }

  @override
  Future<void> insertItem(int index, EngineItem item) async {
    _items.insert(index, item as UsbExclusiveItem);
    if (index <= _index) _index++;
  }

  @override
  Future<void> insertItems(int index, List<EngineItem> items) async {
    _items.insertAll(index, items.cast<UsbExclusiveItem>());
    if (index <= _index) _index += items.length;
  }

  @override
  Future<void> removeItem(int index) async {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    if (index < _index) _index--;
  }

  @override
  Future<void> moveItem(int from, int to) async {
    if (from < 0 || from >= _items.length) return;
    final it = _items.removeAt(from);
    _items.insert(to, it);
    if (from == _index) {
      _index = to;
    } else if (from < _index && to >= _index) {
      _index--;
    } else if (from > _index && to <= _index) {
      _index++;
    }
  }

  @override
  Duration get position => _position;

  @override
  int? get currentIndex => _items.isEmpty ? null : _index;

  @override
  int get sequenceLength => _items.length;

  @override
  bool get hasLoadedSource => _hasLoaded;

  @override
  bool get playing => _playing;

  @override
  EngineProcessingState get processingState => _processingState;

  @override
  EngineLoopMode get loopMode => _loopMode;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _buffered.stream;

  @override
  Stream<EnginePlaybackState> get playbackStateStream => _states.stream;

  @override
  Stream<EngineError> get errorStream => _errors.stream;

  @override
  Stream<int?> get currentIndexStream => _indices.stream;
}
