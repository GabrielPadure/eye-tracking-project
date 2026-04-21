/// Configuration for the Python/MediaPipe backend connection and eye-tracking
/// behaviour. Edited by the user in [SettingsScreen].
class BackendConfig {
  final String host;
  final int port;

  /// How long (ms) the gaze must dwell on a symbol tile before it is selected.
  final int dwellDurationMs;

  const BackendConfig({
    this.host = '192.168.1.100',
    this.port = 8765,
    this.dwellDurationMs = 1500,
  });

  /// WebSocket URL derived from [host] and [port].
  String get wsUrl => 'ws://$host:$port';

  BackendConfig copyWith({String? host, int? port, int? dwellDurationMs}) {
    return BackendConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      dwellDurationMs: dwellDurationMs ?? this.dwellDurationMs,
    );
  }
}
