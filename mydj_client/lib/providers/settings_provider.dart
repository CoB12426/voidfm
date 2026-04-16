import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dj_preferences.dart';

enum ConnectionStatus { unconfigured, connected, error }

class SettingsProvider extends ChangeNotifier {
  static const _keyHostAddress   = 'host_address';
  static const _keyPort          = 'port';
  static const _keyLlmModel     = 'llm_model';
  static const _keyLanguage     = 'language';
  static const _keyTalkLength   = 'talk_length';
  static const _keyDjVoice      = 'dj_voice';
  static const _keyWeatherCity  = 'weather_city';
  static const _keyPersonality  = 'personality';

  String _hostAddress = '';
  int _port = 8000;
  DjPreferences _djPreferences = const DjPreferences();
  ConnectionStatus _connectionStatus = ConnectionStatus.unconfigured;

  String get hostAddress => _hostAddress;
  int get port => _port;
  DjPreferences get djPreferences => _djPreferences;
  ConnectionStatus get connectionStatus => _connectionStatus;

  bool get isConfigured => _hostAddress.isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _hostAddress = prefs.getString(_keyHostAddress) ?? '';
    _port = prefs.getInt(_keyPort) ?? 8000;
    _djPreferences = DjPreferences(
      llmModel:    prefs.getString(_keyLlmModel),
      language:    prefs.getString(_keyLanguage)    ?? 'ja',
      talkLength:  prefs.getString(_keyTalkLength)  ?? 'medium',
      djVoice:     prefs.getString(_keyDjVoice)     ?? 'default',
      weatherCity: prefs.getString(_keyWeatherCity) ?? '',
      personality: prefs.getString(_keyPersonality) ?? 'standard',
    );
    _connectionStatus = ConnectionStatus.unconfigured;
    notifyListeners();
  }

  Future<void> saveConnection(String hostAddress, int port) async {
    _hostAddress = hostAddress;
    _port = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHostAddress, hostAddress);
    await prefs.setInt(_keyPort, port);
    notifyListeners();
  }

  Future<void> saveDjPreferences(DjPreferences prefs) async {
    _djPreferences = prefs;
    final sp = await SharedPreferences.getInstance();
    if (prefs.llmModel != null) await sp.setString(_keyLlmModel, prefs.llmModel!);
    await sp.setString(_keyLanguage,    prefs.language);
    await sp.setString(_keyTalkLength,  prefs.talkLength);
    await sp.setString(_keyDjVoice,     prefs.djVoice);
    await sp.setString(_keyWeatherCity, prefs.weatherCity);
    await sp.setString(_keyPersonality, prefs.personality);
    notifyListeners();
  }

  void setConnectionStatus(ConnectionStatus status) {
    _connectionStatus = status;
    notifyListeners();
  }
}
