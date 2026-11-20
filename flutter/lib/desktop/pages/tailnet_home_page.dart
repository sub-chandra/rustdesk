import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'desktop_tab_page.dart';

const _manualDevicesKey = 'tailnet-devices';
const _defaultPort = 21118;

class _Endpoint {
  const _Endpoint(this.id, this.address, this.port);

  final String id;
  final InternetAddress address;
  final int port;

  String get key => '${address.address}|$port';

  static _Endpoint? parse(String input) {
    final id = input.trim();
    var address = InternetAddress.tryParse(id);
    var port = _defaultPort;
    if (address == null) {
      final match = RegExp(r'^(?:\[([^\]]+)\]|([^:]+)):(\d+)$').firstMatch(id);
      if (match == null) return null;
      address = InternetAddress.tryParse(match[1] ?? match[2]!);
      port = int.tryParse(match[3]!) ?? 0;
    }
    if (address == null || port < 1 || port > 65535 || id.contains('%')) {
      return null;
    }
    final bytes = address.rawAddress;
    final allowed = bytes.length == 4
        ? bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128
        : bytes[0] == 0xfd &&
            bytes[1] == 0x7a &&
            bytes[2] == 0x11 &&
            bytes[3] == 0x5c &&
            bytes[4] == 0xa1 &&
            bytes[5] == 0xe0;
    return allowed ? _Endpoint(id, address, port) : null;
  }
}

class _Device {
  const _Device(this.endpoint, this.name, this.online);

  final _Endpoint endpoint;
  final String name;
  final bool? online;
}

class TailnetHomePage extends StatefulWidget {
  const TailnetHomePage({super.key});

  @override
  State<TailnetHomePage> createState() => _TailnetHomePageState();
}

class _TailnetHomePageState extends State<TailnetHomePage> {
  final _peers = gFFI.recentPeersModel;
  final _manual = <String>[];
  Map<String, _Device> _tailnet = {};
  Map<InternetAddress, _Device> _knownAddresses = {};
  List<_Endpoint> _self = [];
  String? _selection;
  Timer? _timer;
  bool _reading = false;
  bool _running = false;
  bool _checkingUpdate = false;
  bool _probing = false;
  String? _probeResult;
  String? _updateResult;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _t(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _manual.addAll(bind
        .mainGetLocalOption(key: _manualDevicesKey)
        .split(',')
        .where((id) => _Endpoint.parse(id) != null));
    _peers.addListener(_onRecent);
    bind.mainLoadRecentPeers();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _peers.removeListener(_onRecent);
    super.dispose();
  }

  void _onRecent() {
    if (mounted) setState(() {});
  }

  Iterable<_Endpoint> _addresses(dynamic value) sync* {
    if (value is! List) return;
    for (final item in value.whereType<String>()) {
      final endpoint = _Endpoint.parse(item);
      if (endpoint != null) yield endpoint;
    }
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    final nodes = <String, _Device>{};
    final knownAddresses = <InternetAddress, _Device>{};
    var self = <_Endpoint>[];
    var running = false;
    try {
      final folders = Platform.environment;
      final programFiles = folders['ProgramW6432'] ?? folders['ProgramFiles'];
      final executable = programFiles == null
          ? null
          : '$programFiles\\Tailscale\\tailscale.exe';
      if (executable == null || !await File(executable).exists()) return;
      final result =
          await Process.run(executable, ['status', '--json']).timeout(
        const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return;
      final state = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      running = state['BackendState'] == 'Running';
      if (!running) return;
      self = _addresses(state['Self']?['TailscaleIPs']).toList();
      final peers = state['Peer'] as Map<String, dynamic>?;
      for (final node in peers?.values ?? []) {
        if (node is! Map<String, dynamic> || node['ShareeNode'] == true) {
          continue;
        }
        final addresses = _addresses(node['TailscaleIPs']).toList();
        final endpoint = addresses
                .where((ip) => ip.address.type == InternetAddressType.IPv4)
                .firstOrNull ??
            addresses.firstOrNull;
        if (endpoint == null) continue;
        final hostname = node['HostName'] as String? ?? '';
        final device = _Device(
          endpoint,
          hostname.isEmpty ? endpoint.id : hostname,
          node['Online'] as bool?,
        );
        nodes[endpoint.key] = device;
        for (final address in addresses) {
          knownAddresses[address.address] = device;
        }
      }
    } catch (_) {
      running = false;
    } finally {
      _reading = false;
      if (mounted) {
        setState(() {
          _tailnet = nodes;
          _knownAddresses = knownAddresses;
          _self = self;
          _running = running;
        });
      }
    }
  }

  List<_Device> _devices() {
    final result = <String, _Device>{};
    for (final peer in _peers.peers) {
      final endpoint = _Endpoint.parse(peer.id);
      if (endpoint == null) continue;
      final known = _knownAddresses[endpoint.address];
      final name = peer.alias.isNotEmpty ? peer.alias : peer.hostname;
      result.putIfAbsent(
        endpoint.key,
        () => _Device(
          endpoint,
          name.isEmpty ? known?.name ?? endpoint.id : name,
          known?.online,
        ),
      );
    }
    for (final id in _manual) {
      final endpoint = _Endpoint.parse(id);
      if (endpoint == null) continue;
      result.putIfAbsent(endpoint.key, () {
        final known = _knownAddresses[endpoint.address];
        return _Device(endpoint, known?.name ?? id, known?.online);
      });
    }
    for (final entry in _tailnet.entries) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
    return result.values
        .where((device) =>
            !_self.any((local) => local.address == device.endpoint.address))
        .toList();
  }

  Future<void> _addDevice() async {
    String input = '';
    var invalid = false;
    final endpoint = await showDialog<_Endpoint>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, redraw) {
          void submit() {
            final endpoint = _Endpoint.parse(input);
            if (endpoint == null) {
              redraw(() => invalid = true);
            } else {
              Navigator.pop(dialogContext, endpoint);
            }
          }

          return AlertDialog(
            title: Text(_t('按 IP 添加设备', 'Add device by IP')),
            content: TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Tailscale IP',
                hintText: '100.x.x.x:21118',
                errorText: invalid
                    ? _t('请输入有效的 Tailscale IP 和端口',
                        'Enter a valid Tailscale IP and port')
                    : null,
              ),
              onChanged: (value) => input = value,
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(translate('Cancel')),
              ),
              FilledButton(onPressed: submit, child: Text(translate('Add'))),
            ],
          );
        },
      ),
    );
    if (endpoint == null || !mounted) return;
    if (!_manual.any((id) => _Endpoint.parse(id)?.key == endpoint.key)) {
      _manual.add(endpoint.id);
      await bind.mainSetLocalOption(
        key: _manualDevicesKey,
        value: _manual.join(','),
      );
    }
    if (mounted) _select(endpoint.key);
  }

  void _select(String key) => setState(() {
        _selection = key;
        _probeResult = null;
      });

  Future<void> _test(_Endpoint endpoint) async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    var reachable = false;
    try {
      final source = _self
          .where((local) => local.address.type == endpoint.address.type)
          .firstOrNull;
      if (source != null) {
        final socket = await Socket.connect(
          endpoint.address,
          endpoint.port,
          sourceAddress: source.address,
          timeout: const Duration(seconds: 3),
        );
        socket.destroy();
        reachable = true;
      }
    } on SocketException {
      reachable = false;
    } finally {
      if (mounted) {
        setState(() {
          _probing = false;
          if (_selection == null || _selection == endpoint.key) {
            _probeResult = reachable
                ? _t('RustDesk 端口可达', 'RustDesk port reachable')
                : _t('RustDesk 端口不可达', 'RustDesk port unreachable');
          }
        });
      }
    }
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _checkingUpdate = true;
      _updateResult = null;
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    var result = _t('检查失败，请重试', 'Check failed. Try again.');
    try {
      final request = await client.getUrl(Uri.https(
        'api.github.com',
        '/repos/rustdesk/rustdesk/releases/latest',
      ));
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.userAgentHeader, 'RustDeskTailnet');
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode == HttpStatus.ok) {
        final tag = jsonDecode(await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5)))['tag_name'];
        if (tag is String && RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(tag)) {
          final base = await bind.mainGetVersion();
          result = tag.replaceFirst('v', '') == base.split('+').first
              ? _t('已基于官方最新版 $tag', 'Based on the latest official release $tag')
              : _t('本版基于 $base · 官方最新版 $tag',
                  'Based on $base · latest official release $tag');
        }
      }
    } catch (_) {
      // The error text remains visible in the home page.
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _checkingUpdate = false;
          _updateResult = result;
        });
      }
    }
  }

  String _status(_Device device) => switch (device.online) {
        true => _t('在线', 'Online'),
        false => _t('离线', 'Offline'),
        null => _t('状态未知', 'Status unknown'),
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final devices = _devices();
    final selected = devices
            .where((device) => device.endpoint.key == _selection)
            .firstOrNull ??
        devices.firstOrNull;
    final selfAddress = _self.firstOrNull;
    final port = int.tryParse(
          bind.mainGetOptionSync(key: kOptionDirectAccessPort),
        ) ??
        _defaultPort;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 236,
          color: colors.surfaceContainer,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                child: Row(children: [
                  Expanded(
                    child: Text(_t('我的设备', 'My devices'),
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    onPressed: _addDevice,
                    tooltip: _t('按 IP 添加设备', 'Add device by IP'),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return ListTile(
                      selected: device.endpoint.key == selected?.endpoint.key,
                      selectedTileColor: colors.secondaryContainer,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      leading: const Icon(Icons.computer_outlined),
                      title: Text(device.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_status(device)),
                      onTap: () => _select(device.endpoint.key),
                    );
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: Text(translate('Settings')),
                onTap: DesktopTabPage.onAddSetting,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(children: [
                Icon(_running ? Icons.link : Icons.link_off, size: 19),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_running
                      ? 'Tailscale · ${selfAddress?.id ?? _t('已连接', 'Connected')}'
                      : _t('Tailscale 未连接', 'Tailscale disconnected')),
                ),
                IconButton(
                  onPressed: _refresh,
                  tooltip: _t('刷新设备', 'Refresh devices'),
                  icon: const Icon(Icons.refresh),
                ),
              ]),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xff142939), Color(0xff115e59)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(26),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.desktop_windows_outlined,
                          color: Color(0xff9deadd), size: 42),
                      const SizedBox(height: 20),
                      Text(
                        selected?.name ?? _t('选择一台设备', 'Select a device'),
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(color: Colors.white),
                      ),
                      if (selected != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${_status(selected)}  ·  ${selected.endpoint.id}',
                          style: const TextStyle(color: Color(0xffc5eee9)),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xffa2efd6),
                          foregroundColor: const Color(0xff142939),
                        ),
                        icon: const Icon(Icons.arrow_forward),
                        label: Text(_t('进入桌面', 'Open desktop')),
                        onPressed: selected == null ||
                                !_running ||
                                bind.isIncomingOnly()
                            ? null
                            : () => connect(context, selected.endpoint.id),
                      ),
                    ],
                  ),
                ),
              ),
              if (selected != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.network_check),
                  title: Text(_probeResult ?? _t('测试直连端口', 'Test direct port')),
                  onTap: !_running ||
                          _probing ||
                          !_knownAddresses
                              .containsKey(selected.endpoint.address)
                      ? null
                      : () => _test(selected.endpoint),
                ),
              const SizedBox(height: 12),
              Text(
                _t('本机被控端口 $port', 'Local incoming port $port'),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (!bind.mainIsInstalled() && !bind.isDisableInstallation())
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => bind.mainGotoInstall(),
                    icon: const Icon(Icons.desktop_windows_outlined),
                    label: Text(_t('安装为被控服务', 'Install for unattended access')),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _checkingUpdate ? null : _checkUpdate,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(_checkingUpdate
                      ? _t('正在检查…', 'Checking…')
                      : _t('检查 RustDesk 官方更新',
                          'Check official RustDesk releases')),
                ),
              ),
              if (_updateResult != null) ...[
                const SizedBox(height: 8),
                Text(_updateResult!),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
