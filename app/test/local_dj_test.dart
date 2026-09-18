import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/services/local_client.dart';
import 'package:voidfm/services/supertonic_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.voidfm/local_dj');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('readiness requires both the Gemma and Supertonic 3 models', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return {'hasModel': true, 'hasTtsModel': false};
      }
      fail('Unexpected native call: ${call.method}');
    });
    expect(await LocalDjClient().ping(), isFalse);
  });

  test('Supertonic samples become valid little-endian mono WAV', () {
    final wav = encodePcm16Wav(Float32List.fromList([-1, 0, 1]), 24000);
    final bytes = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(bytes.getUint32(24, Endian.little), 24000);
    expect(bytes.getUint16(22, Endian.little), 1);
    expect(bytes.getUint16(34, Endian.little), 16);
    expect(bytes.getUint32(40, Endian.little), 6);
    expect(bytes.getInt16(44, Endian.little), -32768);
    expect(bytes.getInt16(46, Endian.little), 0);
    expect(bytes.getInt16(48, Endian.little), 32767);
  });
}
