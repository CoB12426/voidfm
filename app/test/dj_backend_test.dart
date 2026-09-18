import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/services/dj_backend.dart';
import 'package:voidfm/services/local_client.dart';
import 'package:voidfm/services/remote_client.dart';

void main() {
  test('unknown or missing mode falls back to the PC host', () {
    expect(DjBackendMode.parse(null), DjBackendMode.remote);
    expect(DjBackendMode.parse('bogus'), DjBackendMode.remote);
    expect(DjBackendMode.parse('local'), DjBackendMode.local);
  });

  test('config creates the matching backend', () {
    const remote = BackendConfig(
        mode: DjBackendMode.remote, hostAddress: '10.0.0.2', port: 8000);
    const local = BackendConfig(mode: DjBackendMode.local);

    final r = remote.create();
    expect(r, isA<RemoteHostClient>());
    expect((r as RemoteHostClient).hostAddress, '10.0.0.2');
    r.close();
    expect(local.create(), isA<LocalDjClient>());
    expect(local.audioContentType, 'audio/wav');
  });
}
