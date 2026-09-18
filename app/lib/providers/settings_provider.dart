import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dj_preferences.dart';
import '../models/host_config.dart';
import '../services/dj_backend.dart';
import '../services/local_client.dart';

enum ConnectionStatus { unconfigured, connected, error }

class SettingsProvider extends ChangeNotifier {
  static const _keyBackendMode = 'backend_mode';
  static const _keyHostAddress = 'host_address';
  static const _keyPort = 'port';
  static const _keyLlmModel = 'llm_model';
  static const _keyTtsSpeaker = 'tts_speaker';
  static const _keyLocalVoice = 'local_voice';
  static const _keyTtsSpeed = 'tts_speed';
  static const _keyTalkLength = 'talk_length';
  static const _keyPersonality = 'personality';
  static const _keyUsername = 'username';
  static const _keyDjName = 'dj_name';
  static const _keyCustomPrompt = 'custom_prompt';
  static const _keyTalkFrequency = 'talk_frequency';

  DjBackendMode _backendMode = DjBackendMode.remote;
  String _hostAddress = '';
  int _port = 8000;
  bool _hasLocalModels = false;
  DjPreferences _djPreferences = const DjPreferences();
  ConnectionStatus _connectionStatus = ConnectionStatus.unconfigured;
  String? _verifiedHost; // 疎通確認に成功した "address:port"

  DjBackendMode get backendMode => _backendMode;
  String get hostAddress => _hostAddress;
  int get port => _port;
  bool get hasLocalModels => _hasLocalModels;
  DjPreferences get djPreferences => _djPreferences;
  ConnectionStatus get connectionStatus => _connectionStatus;

  BackendConfig get backend => BackendConfig(
        mode: _backendMode,
        hostAddress: _hostAddress,
        port: _port,
      );

  bool get isConfigured => _backendMode == DjBackendMode.remote
      ? _hostAddress.isNotEmpty
      : _hasLocalModels;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _backendMode = DjBackendMode.parse(prefs.getString(_keyBackendMode));
    _hostAddress = prefs.getString(_keyHostAddress) ?? '';
    _port = prefs.getInt(_keyPort) ?? 8000;
    _djPreferences = DjPreferences(
      llmModel: prefs.getString(_keyLlmModel),
      ttsSpeaker: prefs.getString(_keyTtsSpeaker),
      localVoice: prefs.getString(_keyLocalVoice),
      ttsSpeed: prefs.getDouble(_keyTtsSpeed) ?? 0.85,
      talkLength: prefs.getString(_keyTalkLength) ?? 'medium',
      personality: prefs.getString(_keyPersonality) ?? 'standard',
      username: prefs.getString(_keyUsername) ?? '',
      djName: prefs.getString(_keyDjName) ?? '',
      customPrompt: prefs.getString(_keyCustomPrompt) ?? '',
      talkFrequency: prefs.getInt(_keyTalkFrequency) ?? 1,
    );
    _hasLocalModels = await LocalDjClient.hasModels();
    _connectionStatus = _initialStatus();
    notifyListeners();
  }

  ConnectionStatus _initialStatus() => switch (_backendMode) {
        DjBackendMode.local => _hasLocalModels
            ? ConnectionStatus.connected
            : ConnectionStatus.unconfigured,
        DjBackendMode.remote => isHostVerified(_hostAddress, _port)
            ? ConnectionStatus.connected
            : ConnectionStatus.unconfigured,
      };

  /// このアプリ起動中に [hostAddress]:[port] への接続確認が成功しているか。
  bool isHostVerified(String hostAddress, int port) =>
      hostAddress.isNotEmpty && _verifiedHost == '$hostAddress:$port';

  /// 設定画面の Connect 結果を記録する。
  void setHostVerified(String hostAddress, int port, bool ok) {
    _verifiedHost = ok ? '$hostAddress:$port' : null;
    setConnectionStatus(
        ok ? ConnectionStatus.connected : ConnectionStatus.error);
  }

  Future<void> saveBackendMode(DjBackendMode mode) async {
    if (_backendMode == mode) return;
    _backendMode = mode;
    _connectionStatus = _initialStatus();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBackendMode, mode.name);
    notifyListeners();
  }

  void setLocalModelsAvailable(bool available) {
    _hasLocalModels = available;
    if (_backendMode == DjBackendMode.local) {
      _connectionStatus = _initialStatus();
    }
    notifyListeners();
  }

  Future<void> saveConnection(String hostAddress, int port) async {
    final changed = _hostAddress != hostAddress || _port != port;
    _hostAddress = hostAddress;
    _port = port;
    if (changed && _backendMode == DjBackendMode.remote) {
      _connectionStatus = _initialStatus();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHostAddress, hostAddress);
    await prefs.setInt(_keyPort, port);
    notifyListeners();
  }

  Future<void> saveDjPreferences(DjPreferences prefs) async {
    _djPreferences = prefs;
    final sp = await SharedPreferences.getInstance();
    Future<void> setOrRemove(String key, String? value) =>
        value != null ? sp.setString(key, value) : sp.remove(key);
    await setOrRemove(_keyLlmModel, prefs.llmModel);
    await setOrRemove(_keyTtsSpeaker, prefs.ttsSpeaker);
    await setOrRemove(_keyLocalVoice, prefs.localVoice);
    await sp.setDouble(_keyTtsSpeed, prefs.ttsSpeed);
    await sp.setString(_keyTalkLength, prefs.talkLength);
    await sp.setString(_keyPersonality, prefs.personality);
    await sp.setString(_keyUsername, prefs.username);
    await sp.setString(_keyDjName, prefs.djName);
    await sp.setString(_keyCustomPrompt, prefs.customPrompt);
    await sp.setInt(_keyTalkFrequency, prefs.talkFrequency);
    notifyListeners();
  }

  Future<bool> repairWithHostConfig(HostConfig config) async {
    var repaired = _djPreferences;
    var changed = false;

    if (config.llmModels.isNotEmpty &&
        (repaired.llmModel == null ||
            !config.llmModels.contains(repaired.llmModel))) {
      repaired = repaired.copyWith(llmModel: config.defaultLlm);
      changed = true;
    }

    if (config.ttsSpeakers.isNotEmpty &&
        (repaired.ttsSpeaker == null ||
            !config.ttsSpeakers.contains(repaired.ttsSpeaker))) {
      repaired = repaired.copyWith(ttsSpeaker: config.defaultSpeaker);
      changed = true;
    }

    if (!changed) return false;
    await saveDjPreferences(repaired);
    debugPrint(
        'SettingsProvider: repaired host-bound preferences from /config');
    return true;
  }

  void setConnectionStatus(ConnectionStatus status) {
    _connectionStatus = status;
    notifyListeners();
  }
}
