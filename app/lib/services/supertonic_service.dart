import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../models/tts_voice.dart';

/// Keeps the ONNX model loaded off the UI isolate between DJ breaks.
class SupertonicService {
  SupertonicService._();
  static final instance = SupertonicService._();

  Isolate? _isolate;
  ReceivePort? _responses;
  SendPort? _requests;
  Future<void>? _starting;
  String? _modelPath;
  int _nextId = 0;
  final Map<int, Completer<Uint8List>> _pending = {};

  /// ONNX モデルを保持した isolate が起動しているか。
  bool get isLoaded => _requests != null;

  Future<void> initialize(String modelPath) async {
    if (_modelPath == modelPath && _requests != null) return;
    if (_modelPath != modelPath) reset();
    _modelPath = modelPath;
    _starting ??= _start(modelPath);
    try {
      await _starting;
    } catch (_) {
      reset();
      rethrow;
    }
  }

  Future<void> _start(String modelPath) async {
    final ready = Completer<void>();
    _responses = ReceivePort();
    _responses!.listen((message) {
      if (message is! Map) return;
      if (message['port'] is SendPort) {
        _requests = message['port'] as SendPort;
        if (!ready.isCompleted) ready.complete();
      } else if (message['startupError'] != null) {
        if (!ready.isCompleted) {
          ready.completeError(
              StateError('Supertonic 3: ${message['startupError']}'));
        }
      } else if (message['id'] is int) {
        final completer = _pending.remove(message['id']);
        if (completer == null) return;
        if (message['error'] != null) {
          completer
              .completeError(StateError('Supertonic 3: ${message['error']}'));
        } else {
          completer.complete(message['audio'] as Uint8List);
        }
      }
    });
    _isolate = await Isolate.spawn(
        _supertonicWorker, [_responses!.sendPort, modelPath]);
    await ready.future.timeout(const Duration(seconds: 60));
  }

  Future<Uint8List> synthesize(
    String modelPath,
    String text, {
    String? speaker,
    double speed = 0.85,
  }) async {
    await initialize(modelPath);
    final id = ++_nextId;
    final result = Completer<Uint8List>();
    _pending[id] = result;
    _requests!.send({
      'id': id,
      'text': text,
      'speaker': TtsVoice.validated(speaker),
      'speed': speed.clamp(0.75, 1.1),
    });
    return result.future.timeout(const Duration(seconds: 90), onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('Supertonic 3 synthesis timed out');
    });
  }

  void reset() {
    for (final pending in _pending.values) {
      if (!pending.isCompleted)
        pending.completeError(StateError('TTS model was replaced'));
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _responses?.close();
    _isolate = null;
    _responses = null;
    _requests = null;
    _starting = null;
    _modelPath = null;
  }
}

void _supertonicWorker(List<Object> args) {
  final reply = args[0] as SendPort;
  final directory = args[1] as String;
  final requests = ReceivePort();
  try {
    sherpa.initBindings();
    String path(String name) => '$directory/$name';
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        supertonic: sherpa.OfflineTtsSupertonicModelConfig(
          durationPredictor: path('duration_predictor.int8.onnx'),
          textEncoder: path('text_encoder.int8.onnx'),
          vectorEstimator: path('vector_estimator.int8.onnx'),
          vocoder: path('vocoder.int8.onnx'),
          ttsJson: path('tts.json'),
          unicodeIndexer: path('unicode_indexer.bin'),
          voiceStyle: path('voice.bin'),
        ),
        numThreads: 2,
        debug: false,
      ),
    );
    final tts = sherpa.OfflineTts(config);
    if (tts.sampleRate <= 0)
      throw StateError('Could not load Supertonic model');
    reply.send({'port': requests.sendPort});
    requests.listen((message) {
      final request = message as Map;
      final id = request['id'] as int;
      try {
        final audio = tts.generateWithConfig(
          text: request['text'] as String,
          config: sherpa.OfflineTtsGenerationConfig(
            sid: TtsVoice.speakerId(request['speaker'] as String?),
            numSteps: 8,
            speed: (request['speed'] as num).toDouble(),
            extra: const {'lang': 'en'},
          ),
        );
        if (audio.sampleRate <= 0 || audio.samples.isEmpty) {
          throw StateError('The model returned no audio');
        }
        reply.send({
          'id': id,
          'audio': encodePcm16Wav(audio.samples, audio.sampleRate)
        });
      } catch (error) {
        reply.send({'id': id, 'error': error.toString()});
      }
    });
  } catch (error) {
    reply.send({'startupError': error.toString()});
    requests.close();
  }
}

/// A standard mono PCM WAV suitable for the existing just_audio pipeline.
Uint8List encodePcm16Wav(Float32List samples, int sampleRate) {
  if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
  final bytes = Uint8List(44 + samples.length * 2);
  final header = ByteData.sublistView(bytes);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    final pcm =
        clamped < 0 ? (clamped * 32768).round() : (clamped * 32767).round();
    header.setInt16(44 + i * 2, pcm, Endian.little);
  }
  return bytes;
}
