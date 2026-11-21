import 'dart:convert';
import 'dart:io';

bool isTailnetAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128;
  }
  return bytes[0] == 0xfd &&
      bytes[1] == 0x7a &&
      bytes[2] == 0x11 &&
      bytes[3] == 0x5c &&
      bytes[4] == 0xa1 &&
      bytes[5] == 0xe0;
}

Future<Map<String, dynamic>> readTailnetStatus() async {
  final folders = Platform.environment;
  final programFiles = folders['ProgramW6432'] ?? folders['ProgramFiles'];
  if (programFiles == null) throw StateError('Tailscale is unavailable');
  final executable = '$programFiles\\Tailscale\\tailscale.exe';
  final result = await Process.run(
    executable,
    ['status', '--json'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(seconds: 5));
  if (result.exitCode != 0) throw StateError('Tailscale status is unavailable');
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

Iterable<InternetAddress> tailnetAddresses(dynamic value) sync* {
  if (value is! List) return;
  for (final text in value.whereType<String>()) {
    final ip = InternetAddress.tryParse(text);
    if (ip != null && isTailnetAddress(ip)) yield ip;
  }
}
