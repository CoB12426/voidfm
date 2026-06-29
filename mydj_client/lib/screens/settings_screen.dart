import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/settings_provider.dart';
import '../models/dj_preferences.dart';
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
  final _usernameCtrl = TextEditingController();
  final _djNameCtrl = TextEditingController();
  final _customPromptCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isTesting = false;
  bool _isConnected = false;
  bool _isDetectingLocation = false;

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
  static const _personalityLabels = ['スタンダード', 'ハイテンション', 'チル', 'インテリ', 'お笑い系'];

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _hostCtrl.text = settings.hostAddress;
    _portCtrl.text = settings.port.toString();
    final prefs = settings.djPreferences;
    _talkLength = prefs.talkLength;
    _personality = prefs.personality;
    _cityCtrl.text = prefs.weatherCity;
    _usernameCtrl.text = prefs.username;
    _djNameCtrl.text = prefs.djName;
    _customPromptCtrl.text = prefs.customPrompt;
    _talkFrequency = prefs.talkFrequency;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _cityCtrl.dispose();
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
    final client = HostClient(hostAddress: host, port: port);
    try {
      final ok = await client.ping();
      if (!mounted) return;
      if (ok) {
        setState(() => _isConnected = true);
        context
            .read<SettingsProvider>()
            .setConnectionStatus(ConnectionStatus.connected);
        await _loadConfig(client);
      } else {
        _showErrorSnackBar('Connection failed');
        context
            .read<SettingsProvider>()
            .setConnectionStatus(ConnectionStatus.error);
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('Error: $e');
      context
          .read<SettingsProvider>()
          .setConnectionStatus(ConnectionStatus.error);
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _loadConfig(HostClient client) async {
    try {
      final config = await client.fetchConfig();
      if (!mounted) return;
      await context.read<SettingsProvider>().repairWithHostConfig(config);
    } catch (e) {
      debugPrint('fetchConfig error: $e');
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
      talkLength: _talkLength,
      weatherCity: _cityCtrl.text.trim(),
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
              // ---- HOST ----
              _sectionLabel('HOST'),
              const SizedBox(height: 12),

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
                decoration:
                    const InputDecoration(labelText: 'Port', hintText: '8000'),
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
                            width: 16,
                            height: 16,
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

