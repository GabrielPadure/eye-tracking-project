import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/backend_config.dart';
import '../providers/connection_provider.dart';

/// Settings screen: configure the Python backend connection and dwell duration.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late double _dwellMs;

  @override
  void initState() {
    super.initState();
    final config = context.read<ConnectionProvider>().config;
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _dwellMs = config.dwellDurationMs.toDouble();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_portController.text) ?? 8765;
    final config = BackendConfig(
      host: _hostController.text.trim(),
      port: port,
      dwellDurationMs: _dwellMs.round(),
    );
    context.read<ConnectionProvider>().updateConfig(config);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Save',
              style: TextStyle(color: Colors.cyanAccent, fontSize: 16),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ── Backend connection ────────────────────────────────────────────
          const _SectionHeader(title: 'PYTHON BACKEND CONNECTION'),
          const SizedBox(height: 12),
          _SettingsTextField(
            controller: _hostController,
            label: 'Host / IP Address',
            hint: '192.168.1.100',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _SettingsTextField(
            controller: _portController,
            label: 'WebSocket Port',
            hint: '8765',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          Consumer<ConnectionProvider>(
            builder: (context, conn, _) => Text(
              'URL: ${conn.config.wsUrl}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
          const SizedBox(height: 32),

          // ── Eye tracking ──────────────────────────────────────────────────
          const _SectionHeader(title: 'EYE TRACKING'),
          const SizedBox(height: 12),
          Text(
            'Dwell Duration: ${_dwellMs.round()} ms',
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          Slider(
            min: 500,
            max: 3000,
            divisions: 25,
            value: _dwellMs,
            activeColor: Colors.cyanAccent,
            inactiveColor: Colors.white24,
            label: '${_dwellMs.round()} ms',
            onChanged: (v) => setState(() => _dwellMs = v),
          ),
          const SizedBox(height: 32),

          // ── Calibration ───────────────────────────────────────────────────
          const _SectionHeader(title: 'CALIBRATION'),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.adjust),
            label: const Text('Run Calibration'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            onPressed: () => Navigator.pushNamed(context, '/calibration'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.cyanAccent,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.4,
      ),
    );
  }
}

class _SettingsTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType keyboardType;

  const _SettingsTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white54),
        hintStyle: const TextStyle(color: Colors.white24),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.cyanAccent),
        ),
      ),
    );
  }
}
