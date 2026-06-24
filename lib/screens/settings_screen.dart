import 'package:flutter/material.dart';

typedef SettingsChangedCallback = void Function({
  required double eye,
  required double tilt,
  required bool enhance,
  required bool alarm,
  required bool hud,
  required bool devMode,
});

class SettingsScreen extends StatefulWidget {
  final double eyeClosureThreshold;
  final double headTiltSensitivity;
  final bool isImageEnhancementEnabled;
  final bool isAlarmVolumeOn;
  final bool showLiveStatusHud;
  final bool isDeveloperModeEnabled;
  final SettingsChangedCallback onChanged;

  const SettingsScreen({
    super.key,
    required this.eyeClosureThreshold,
    required this.headTiltSensitivity,
    required this.isImageEnhancementEnabled,
    required this.isAlarmVolumeOn,
    required this.showLiveStatusHud,
    required this.isDeveloperModeEnabled,
    required this.onChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _eye;
  late double _tilt;
  late bool _enhance;
  late bool _alarm;
  late bool _hud;
  late bool _devMode;

  @override
  void initState() {
    super.initState();
    _eye = widget.eyeClosureThreshold;
    _tilt = widget.headTiltSensitivity;
    _enhance = widget.isImageEnhancementEnabled;
    _alarm = widget.isAlarmVolumeOn;
    _hud = widget.showLiveStatusHud;
    _devMode = widget.isDeveloperModeEnabled;
  }

  void _propagate() {
    widget.onChanged(
      eye: _eye,
      tilt: _tilt,
      enhance: _enhance,
      alarm: _alarm,
      hud: _hud,
      devMode: _devMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Eye Closure Sensitivity ────────────────────────────────────────
          _SectionHeader(title: 'Eye Closure Threshold'),
          _SettingDescription(
            text: 'Lower values require eyes to be more closed before an alert fires.',
          ),
          Row(
            children: [
              const Text('0.1', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _eye,
                  min: 0.1,
                  max: 0.6,
                  divisions: 10,
                  activeColor: Colors.blueAccent,
                  inactiveColor: Colors.white24,
                  label: _eye.toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => _eye = v);
                    _propagate();
                  },
                ),
              ),
              const Text('0.6', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          _ValueBadge(label: 'Current: ${_eye.toStringAsFixed(2)}'),

          const SizedBox(height: 28),

          // ── Head Tilt Sensitivity ──────────────────────────────────────────
          _SectionHeader(title: 'Head Tilt Sensitivity (°)'),
          _SettingDescription(
            text: 'Sets the angle (in degrees) at which a head tilt triggers a warning.',
          ),
          Row(
            children: [
              const Text('5°', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _tilt,
                  min: 5,
                  max: 45,
                  divisions: 16,
                  activeColor: Colors.blueAccent,
                  inactiveColor: Colors.white24,
                  label: '${_tilt.toStringAsFixed(0)}°',
                  onChanged: (v) {
                    setState(() => _tilt = v);
                    _propagate();
                  },
                ),
              ),
              const Text('45°', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          _ValueBadge(label: 'Current: ${_tilt.toStringAsFixed(0)}°'),

          const SizedBox(height: 28),

          // ── Image Enhancement ──────────────────────────────────────────────
          _SectionHeader(title: 'Image Enhancement'),
          _SettingDescription(
            text: 'Boosts brightness of the camera feed for low-light detection accuracy.',
          ),
          _ToggleTile(
            label: 'Enable Image Enhancement',
            value: _enhance,
            onChanged: (v) {
              setState(() => _enhance = v);
              _propagate();
            },
          ),

          const SizedBox(height: 16),

          // ── Alarm Volume ───────────────────────────────────────────────────
          _SectionHeader(title: 'Alarm Volume'),
          _SettingDescription(
            text: 'Toggle the audible alarm that fires on drowsiness detection.',
          ),
          _ToggleTile(
            label: 'Enable Alarm Sound',
            value: _alarm,
            onChanged: (v) {
              setState(() => _alarm = v);
              _propagate();
            },
          ),

          const SizedBox(height: 16),

          // ── Live Status HUD ────────────────────────────────────────────────
          _SectionHeader(title: 'Live Status HUD'),
          _SettingDescription(
            text: 'Show or hide the real-time telemetry overlay on the map screen.',
          ),
          _ToggleTile(
            label: 'Show HUD',
            value: _hud,
            onChanged: (v) {
              setState(() => _hud = v);
              _propagate();
            },
          ),

          const SizedBox(height: 16),

          // ── Developer Mode ─────────────────────────────────────────────────
          _SectionHeader(title: 'Developer Mode'),
          _SettingDescription(
            text: 'Show the raw camera feed with ML Kit face landmarks and bounding boxes.',
          ),
          _ToggleTile(
            label: 'Enable Developer Mode',
            value: _devMode,
            onChanged: (v) {
              setState(() => _devMode = v);
              _propagate();
            },
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SettingDescription extends StatelessWidget {
  final String text;
  const _SettingDescription({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }
}

class _ValueBadge extends StatelessWidget {
  final String label;
  const _ValueBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.blueAccent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5)),
        ),
        child: Text(label, style: const TextStyle(color: Colors.blueAccent, fontSize: 13)),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
        value: value,
        activeColor: Colors.blueAccent,
        onChanged: onChanged,
      ),
    );
  }
}