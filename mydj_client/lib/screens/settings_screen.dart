import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/settings_provider.dart';
import '../models/dj_preferences.dart';
import '../models/host_config.dart';
import '../services/host_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isTesting = false;
  bool _isLoadingConfig = false;
  bool _isDetectingLocation = false;
  HostConfig? _hostConfig;

  String? _selectedModel;
  String _language = 'ja';
  String _talkLength = 'medium';
  String _djVoice = 'default';
  String _personality = 'standard';

  static const _personalityItems = ['standard', 'energetic', 'chill', 'intellectual', 'comedian'];
  static const _personalityLabels = ['スタンダード', 'ハイテンション', 'チル', 'インテリ', 'お笑い系'];

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _hostCtrl.text = settings.hostAddress;
    _portCtrl.text = settings.port.toString();
    final prefs = settings.djPreferences;
    _selectedModel = prefs.llmModel;
    _language = prefs.language;
    _talkLength = prefs.talkLength;
    _djVoice = prefs.djVoice;
    _personality = prefs.personality;
    _cityCtrl.text = prefs.weatherCity;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isTesting = true);
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8000;
    final client = HostClient(hostAddress: host, port: port);
    try {
      final ok = await client.ping();
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected')),
        );
        context.read<SettingsProvider>().setConnectionStatus(ConnectionStatus.connected);
        await _loadConfig(client);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connection failed')),
        );
        context.read<SettingsProvider>().setConnectionStatus(ConnectionStatus.error);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      context.read<SettingsProvider>().setConnectionStatus(ConnectionStatus.error);
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _loadConfig(HostClient client) async {
    setState(() => _isLoadingConfig = true);
    try {
      final config = await client.fetchConfig();
      if (!mounted) return;
      setState(() {
        _hostConfig = config;
        _selectedModel ??= config.defaultLlm;
      });
    } catch (e) {
      debugPrint('fetchConfig error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingConfig = false);
    }
  }

  Future<void> _detectLocation() async {
    setState(() => _isDetectingLocation = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final lat = position.latitude.toStringAsFixed(4);
      final lon = position.longitude.toStringAsFixed(4);
      if (mounted) setState(() => _cityCtrl.text = '$lat,$lon');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Location error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDetectingLocation = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final settings = context.read<SettingsProvider>();
    await settings.saveConnection(
      _hostCtrl.text.trim(),
      int.tryParse(_portCtrl.text.trim()) ?? 8000,
    );
    await settings.saveDjPreferences(DjPreferences(
      llmModel: _selectedModel,
      language: _language,
      talkLength: _talkLength,
      djVoice: _djVoice,
      weatherCity: _cityCtrl.text.trim(),
      personality: _personality,
    ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final models = _hostConfig?.llmModels ?? [];

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
              style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w600),
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
              // ---- HOST ----
              _sectionLabel('HOST'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _hostCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Address', hintText: '100.x.x.x'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _portCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Port', hintText: '8000'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return (n == null || n < 1 || n > 65535) ? 'Invalid port' : null;
                },
              ),
              const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isTesting ? null : _testConnection,
                  child: _isTesting
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('Test Connection'),
                ),
              ),

              const SizedBox(height: 40),

              // ---- DJ ----
              _sectionLabel('DJ'),
              const SizedBox(height: 12),

              // LLM モデル（サーバー接続後に表示）
              if (_isLoadingConfig)
                const LinearProgressIndicator(color: Colors.white)
              else if (models.isNotEmpty)
                _dropdown(
                  label: 'LLM Model',
                  value: models.contains(_selectedModel) ? _selectedModel! : models.first,
                  items: models,
                  onChanged: (v) => setState(() => _selectedModel = v),
                ),

              const SizedBox(height: 12),

              _dropdown(
                label: 'Language',
                value: _language,
                items: const ['ja', 'en'],
                labels: const ['日本語', 'English'],
                onChanged: (v) => setState(() => _language = v!),
              ),
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
                label: 'DJ Voice',
                value: _djVoice,
                items: const ['default', 'JAMES', 'E-GIRL', 'ETHAN'],
                labels: const ['Default', 'JAMES', 'E-GIRL', 'ETHAN'],
                onChanged: (v) => setState(() => _djVoice = v!),
              ),

              const SizedBox(height: 40),

              // ---- WEATHER ----
              _sectionLabel('WEATHER'),
              const SizedBox(height: 12),

              TextFormField(
                controller: _cityCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'City',
                  hintText: 'Tokyo  (or use GPS)',
                  suffixIcon: _isDetectingLocation
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white54),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.my_location,
                              color: Colors.white54, size: 20),
                          tooltip: 'Detect location',
                          onPressed: _detectLocation,
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Leave empty to use server default. GPS fills in coordinates.',
                style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF555555)),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

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
        value: value,
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
