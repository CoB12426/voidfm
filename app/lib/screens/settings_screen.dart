import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../providers/dj_provider.dart';
import '../providers/settings_provider.dart';
import '../models/tts_voice.dart';
import '../services/audio_service.dart';
import '../services/dj_backend.dart';
import '../services/local_client.dart';
import '../services/remote_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _djNameCtrl = TextEditingController();
  final _customPromptCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  DjBackendMode _mode = DjBackendMode.remote;
  bool _isTesting = false;
  bool _isConnected = false;

  // 端末内モデル
  bool _isImporting = false;
  bool _hasLlmModel = false;
  bool _hasTtsModel = false;
  bool _llmLoaded = false;
  bool _ttsLoaded = false;
  late final DjProvider _dj;
  late final SettingsProvider _settings;
  bool _isPreviewing = false;
  final AudioPlayer _previewPlayer = AudioPlayer();
  String _localVoice = TtsVoice.defaultId;
  double _ttsSpeed = 0.85;

  String _talkLength = 'medium';
  String _personality = 'standard';
  int _talkFrequency = 1;

  static const _personalityItems = [
    'standard',
    'energetic',
    'chill',
    'intellectual',
    'comedian'
  ];
  static const _personalityLabels = ['Standard', 'Energetic', 'Chill', 'Intellectual', 'Comedian'];

  @override
  void initState() {
    super.initState();
    final settings = _settings = context.read<SettingsProvider>();
    _dj = context.read<DjProvider>();
    _mode = settings.backendMode;
    _hostCtrl.text = settings.hostAddress;
    _portCtrl.text = settings.port.toString();
    _isConnected =
        settings.isHostVerified(settings.hostAddress, settings.port) ||
            (settings.backendMode == DjBackendMode.remote &&
                _dj.isOnAir &&
                _dj.hostConnected == true);
    _refreshLocalModelStatus();
    final prefs = settings.djPreferences;
    _localVoice = TtsVoice.validated(prefs.localVoice);
    _ttsSpeed = prefs.ttsSpeed.clamp(0.75, 1.1).toDouble();
    _talkLength = prefs.talkLength;
    _personality = prefs.personality;
    _usernameCtrl.text = prefs.username;
    _djNameCtrl.text = prefs.djName;
    _customPromptCtrl.text = prefs.customPrompt;
    _talkFrequency = prefs.talkFrequency;
  }

  /// 端末内モデルを使って ON AIR 中か（このときはモデルを保持する）。
  bool get _localOnAir =>
      _dj.isOnAir && _settings.backendMode == DjBackendMode.local;

  @override
  void dispose() {
    // 試聴やインポート確認で読み込んだモデルは、使っていなければ解放する
    if (!_localOnAir) unawaited(LocalDjClient.unload());
    unawaited(_previewPlayer.dispose());
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _djNameCtrl.dispose();
    _customPromptCtrl.dispose();
    super.dispose();
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: const Color(0xFF1A0D0D),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF3A1A1A)),
      ),
      content: Text(
        message,
        style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFFCC4444)),
      ),
    ));
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isTesting = true;
      _isConnected = false;
    });
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8000;
    final client = RemoteHostClient(hostAddress: host, port: port);
    try {
      final ok = await client.ping();
      if (!mounted) return;
      _settings.setHostVerified(host, port, ok);
      if (ok) {
        setState(() => _isConnected = true);
        await _loadConfig(client);
      } else {
        _showErrorSnackBar('Connection failed');
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('Error: $e');
      _settings.setHostVerified(host, port, false);
    } finally {
      client.close();
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _loadConfig(RemoteHostClient client) async {
    try {
      final config = await client.fetchConfig();
      if (!mounted) return;
      await context.read<SettingsProvider>().repairWithHostConfig(config);
    } catch (e) {
      debugPrint('fetchConfig error: $e');
    }
  }

  Future<void> _refreshLocalModelStatus() async {
    try {
      final status = await LocalDjClient.status();
      final loaded = await LocalDjClient.loadedState();
      if (!mounted) return;
      setState(() {
        _hasLlmModel = status['hasModel'] == true;
        _hasTtsModel = status['hasTtsModel'] == true;
        _llmLoaded = loaded.llm;
        _ttsLoaded = loaded.tts;
      });
    } catch (e) {
      debugPrint('local model status error: $e');
    }
  }

  Future<void> _pickModel({required bool isTts}) async {
    setState(() => _isImporting = true);
    try {
      final selected = isTts
          ? await LocalDjClient.pickTtsModel()
          : await LocalDjClient.pickModel();
      if (!mounted || !selected) return;
      final status = await LocalDjClient.status();
      final hasLlm = status['hasModel'] == true;
      final hasTts = status['hasTtsModel'] == true;
      if (hasLlm && hasTts) {
        // 読み込めるモデルか確認し、ON AIR 中でなければすぐ解放する
        await LocalDjClient().initialize();
        if (!_localOnAir) await LocalDjClient.unload();
      }
      _settings.setLocalModelsAvailable(hasLlm && hasTts);
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('Model import failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
        await _refreshLocalModelStatus();
      }
    }
  }

  Future<void> _previewVoice() async {
    setState(() => _isPreviewing = true);
    try {
      final audio = await LocalDjClient.previewVoice(
          speaker: _localVoice, speed: _ttsSpeed);
      await _previewPlayer.stop();
      await _previewPlayer.setAudioSource(
        BytesAudioSource(audio, contentType: 'audio/wav'),
      );
      await _previewPlayer.play();
      await _refreshLocalModelStatus();
    } catch (e) {
      if (mounted) _showErrorSnackBar('Voice preview failed: $e');
    } finally {
      if (mounted) setState(() => _isPreviewing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final settings = context.read<SettingsProvider>();
    await settings.saveBackendMode(_mode);
    if (_mode == DjBackendMode.remote) {
      await settings.saveConnection(
        _hostCtrl.text.trim(),
        int.tryParse(_portCtrl.text.trim()) ?? 8000,
      );
    }
    await settings.saveDjPreferences(settings.djPreferences.copyWith(
      localVoice: _localVoice,
      ttsSpeed: _ttsSpeed,
      talkLength: _talkLength,
      personality: _personality,
      username: _usernameCtrl.text.trim(),
      djName: _djNameCtrl.text.trim(),
      customPrompt: _customPromptCtrl.text.trim(),
      talkFrequency: _talkFrequency,
    ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              'Save',
              style: GoogleFonts.inter(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- ENGINE ----
              _sectionLabel('DJ ENGINE'),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<DjBackendMode>(
                  segments: const [
                    ButtonSegment(
                      value: DjBackendMode.remote,
                      icon: Icon(Icons.computer, size: 18),
                      label: Text('Remote'),
                    ),
                    ButtonSegment(
                      value: DjBackendMode.local,
                      icon: Icon(Icons.smartphone, size: 18),
                      label: Text('On-Device'),
                    ),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) =>
                        states.contains(WidgetState.selected)
                            ? Colors.white
                            : Colors.transparent),
                    foregroundColor: WidgetStateProperty.resolveWith((states) =>
                        states.contains(WidgetState.selected)
                            ? Colors.black
                            : const Color(0xFF777777)),
                    side: WidgetStateProperty.all(
                        const BorderSide(color: Color(0xFF333333))),
                  ),
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _mode == DjBackendMode.remote
                    ? 'Generates talk with an LLM and Chatterbox TTS on your PC. Higher quality, but requires a connection to the host.'
                    : 'Generates talk with Gemma 4 E2B and Supertonic 3 on this phone. Works offline.',
                style: _hintStyle(11),
              ),
              const SizedBox(height: 32),

              if (_mode == DjBackendMode.remote) ...[
                // ---- HOST ----
                _sectionLabel('HOST'),
                const SizedBox(height: 12),
                Text(
                    'Enter the address and port of the VoidFM host running on your PC (run `voidfm status` to see them).',
                    style: _hintStyle(12)),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _hostCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: 'Address', hintText: '100.x.x.x'),
                  onChanged: (_) {
                    if (_isConnected) setState(() => _isConnected = false);
                  },
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _portCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: 'Port', hintText: '8000'),
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_isConnected) setState(() => _isConnected = false);
                  },
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return (n == null || n < 1 || n > 65535)
                        ? 'Invalid port'
                        : null;
                  },
                ),
                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isTesting ? null : _testConnection,
                    style: _isConnected
                        ? ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A3A1A),
                            foregroundColor: const Color(0xFF44CC44),
                          )
                        : null,
                    child: _isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black),
                          )
                        : _isConnected
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.check, size: 16),
                                  const SizedBox(width: 6),
                                  Text('Connected',
                                      style: GoogleFonts.inter(
                                          fontWeight: FontWeight.w600)),
                                ],
                              )
                            : const Text('Connect'),
                  ),
                ),
              ] else
                ..._buildLocalModelSection(),

              const SizedBox(height: 40),

              // ---- DJ ----
              _sectionLabel('DJ'),
              const SizedBox(height: 12),

              _dropdown(
                label: 'Talk Length',
                value: _talkLength,
                items: const ['short', 'medium', 'long'],
                labels: const ['Short', 'Medium', 'Long'],
                onChanged: (v) => setState(() => _talkLength = v!),
              ),
              const SizedBox(height: 12),

              _dropdown(
                label: 'DJ Personality',
                value: _personality,
                items: _personalityItems,
                labels: _personalityLabels,
                onChanged: (v) => setState(() => _personality = v!),
              ),
              const SizedBox(height: 12),

              _dropdown(
                label: 'Talk Frequency',
                value: _talkFrequency.toString(),
                items: const ['1', '2', '3', '4', '5'],
                labels: const [
                  'Every song',
                  'Every 2 songs',
                  'Every 3 songs',
                  'Every 4 songs',
                  'Every 5 songs',
                ],
                onChanged: (v) =>
                    setState(() => _talkFrequency = int.parse(v!)),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _djNameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'DJ Name',
                  hintText: 'e.g. Nova',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Optional. The DJ will introduce themselves by this name.',
                style: GoogleFonts.inter(
                    fontSize: 11, color: const Color(0xFF555555)),
              ),

              const SizedBox(height: 40),

              // ---- LISTENER ----
              _sectionLabel('LISTENER'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _usernameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Your Name',
                  hintText: 'e.g. Alex',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Optional. The DJ will occasionally call you by name.',
                style: GoogleFonts.inter(
                    fontSize: 11, color: const Color(0xFF555555)),
              ),

              const SizedBox(height: 40),

              // ---- CUSTOM PROMPT ----
              _sectionLabel('CUSTOM PROMPT'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _customPromptCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Additional Instructions',
                  hintText:
                      'e.g. This is a study session. Keep the mood calm and focused.',
                  alignLabelWithHint: true,
                ),
                maxLines: 4,
                minLines: 2,
              ),
              const SizedBox(height: 6),
              Text(
                'Optional. Appended to every DJ prompt as extra instructions.',
                style: GoogleFonts.inter(
                    fontSize: 11, color: const Color(0xFF555555)),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle _hintStyle(double size) =>
      GoogleFonts.inter(fontSize: size, color: const Color(0xFF888888));

  Widget _modelButton({
    required bool installed,
    required bool loaded,
    required String name,
    required String pickLabel,
    required VoidCallback onPressed,
  }) =>
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _isImporting ? null : onPressed,
          style: loaded
              ? ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A3A1A),
                  foregroundColor: const Color(0xFF44CC44),
                )
              : installed
                  ? ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A1A1A),
                      foregroundColor: const Color(0xFFAAAAAA),
                    )
                  : null,
          child: _isImporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : installed
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(loaded ? Icons.memory : Icons.check, size: 16),
                        const SizedBox(width: 6),
                        Text(loaded ? '$name · Loaded' : '$name · Installed',
                            style:
                                GoogleFonts.inter(fontWeight: FontWeight.w600)),
                      ],
                    )
                  : Text(pickLabel),
        ),
      );

  List<Widget> _buildLocalModelSection() => [
        _sectionLabel('ON-DEVICE MODEL'),
        const SizedBox(height: 12),
        Text('Select a Gemma 4 E2B IT .litertlm model from this device. It is copied into the app the first time.',
            style: _hintStyle(12)),
        const SizedBox(height: 12),
        _modelButton(
          installed: _hasLlmModel,
          loaded: _llmLoaded,
          name: 'Gemma 4 E2B',
          pickLabel: 'Select Gemma 4 E2B model',
          onPressed: () => _pickModel(isTts: false),
        ),
        const SizedBox(height: 16),
        Text('Select the official Supertonic 3 .tar.bz2 archive. Once extracted, speech is generated offline.',
            style: _hintStyle(12)),
        const SizedBox(height: 12),
        _modelButton(
          installed: _hasTtsModel,
          loaded: _ttsLoaded,
          name: 'Supertonic 3',
          pickLabel: 'Select Supertonic 3 archive',
          onPressed: () => _pickModel(isTts: true),
        ),
        const SizedBox(height: 8),
        Text(
            'Installed = stored on this device (not in memory) / Loaded = currently in memory. '
            'In On-Device mode, models are loaded only while ON AIR and released when you turn it off.',
            style: _hintStyle(11)),
        const SizedBox(height: 20),
        _dropdown(
          label: 'DJ Voice',
          value: _localVoice,
          items: TtsVoice.ids,
          labels: TtsVoice.ids.map(TtsVoice.label).toList(),
          onChanged: (v) => setState(() => _localVoice = v!),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _hasTtsModel && !_isPreviewing ? _previewVoice : null,
          icon: _isPreviewing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow, size: 20),
          label: const Text('Preview voice'),
        ),
        const SizedBox(height: 8),
        Text('Speech Pace  ${_ttsSpeed.toStringAsFixed(2)}×',
            style: GoogleFonts.inter(color: Colors.white70, fontSize: 13)),
        Slider(
          value: _ttsSpeed,
          min: 0.75,
          max: 1.1,
          divisions: 7,
          label: _ttsSpeed.toStringAsFixed(2),
          onChanged: (value) => setState(() => _ttsSpeed = value),
        ),
        Text('Slower speech uses a lower value.',
            style: GoogleFonts.inter(
                fontSize: 11, color: const Color(0xFF555555))),
      ];

  Widget _sectionLabel(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF555555),
          letterSpacing: 2,
        ),
      );

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> items,
    List<String>? labels,
    required void Function(String?) onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        dropdownColor: const Color(0xFF111111),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(labelText: label),
        items: items.asMap().entries.map((e) {
          final display = labels != null ? labels[e.key] : e.value;
          return DropdownMenuItem(value: e.value, child: Text(display));
        }).toList(),
        onChanged: onChanged,
      );
}
