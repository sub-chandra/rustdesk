import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'tailnet_local.dart';

const _port = 21120;
const _path = '/rustdesk-tailnet.zip';
const _publishedKey = 'tailnet-published-update';
const _sourceKey = 'tailnet-update-source';
const _maxPackageBytes = 256 * 1024 * 1024;

Future<bool> _isZip(File file) async {
  final handle = await file.open();
  try {
    final head = await handle.read(4);
    return head.length == 4 &&
        head[0] == 0x50 &&
        head[1] == 0x4b &&
        head[2] == 3 &&
        head[3] == 4;
  } finally {
    await handle.close();
  }
}

class TailnetPackageServer {
  static final instance = TailnetPackageServer._();
  TailnetPackageServer._();

  HttpServer? _server;
  File? _package;

  Uri? get address {
    final server = _server;
    return server == null
        ? null
        : Uri(
            scheme: 'http',
            host: server.address.address,
            port: _port,
            path: _path);
  }

  Future<void> restore() async {
    final saved = bind.mainGetLocalOption(key: _publishedKey);
    if (saved.isEmpty) return;
    try {
      await publish(saved);
    } catch (error) {
      debugPrint('Could not start Tailnet update sharing: $error');
    }
  }

  Future<void> publish(String path) async {
    final file = File(path);
    if (!path.toLowerCase().endsWith('.zip') ||
        await file.length() > _maxPackageBytes ||
        !await _isZip(file)) {
      throw StateError('Select a RustDesk Tailnet ZIP package');
    }
    if (_server == null) {
      final status = await readTailnetStatus();
      final addresses = tailnetAddresses(status['Self']?['TailscaleIPs']);
      final local = addresses
              .where((ip) => ip.type == InternetAddressType.IPv4)
              .firstOrNull ??
          addresses.firstOrNull;
      if (status['BackendState'] != 'Running' || local == null) {
        throw StateError('Connect Tailscale first');
      }
      final server = await HttpServer.bind(local, _port);
      server.idleTimeout = const Duration(seconds: 15);
      _server = server;
      server.listen(_serve);
    }
    _package = file;
    await bind.mainSetLocalOption(key: _publishedKey, value: path);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _package = null;
    await bind.mainSetLocalOption(key: _publishedKey, value: '');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final peer = request.connectionInfo?.remoteAddress;
    final file = _package;
    if (request.method != 'GET' ||
        request.uri.path != _path ||
        peer == null ||
        !isTailnetAddress(peer) ||
        file == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    try {
      final bytes = await file.length();
      if (bytes > _maxPackageBytes || !await _isZip(file)) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.headers.contentType = ContentType('application', 'zip');
        response.headers.set('Content-Disposition',
            'attachment; filename="RustDeskTailnet-windows-x64.zip"');
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.contentLength = bytes;
        await response.addStream(file.openRead());
      }
    } catch (error) {
      debugPrint('Tailnet update transfer ended: $error');
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The peer may have canceled the download.
      }
    }
  }
}

Future<void> downloadTailnetPackage(
    InternetAddress host, String destination) async {
  final status = await readTailnetStatus();
  final peers = status['Peer'] as Map<String, dynamic>?;
  final known = peers?.values.whereType<Map<String, dynamic>>().any(
          (node) => tailnetAddresses(node['TailscaleIPs']).contains(host)) ??
      false;
  final local = tailnetAddresses(status['Self']?['TailscaleIPs'])
      .where((ip) => ip.type == host.type)
      .firstOrNull;
  if (status['BackendState'] != 'Running' || !known || local == null) {
    throw StateError('Select a known Tailscale update host');
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'DIRECT';
  client.connectionFactory =
      (_, __, ___) => Socket.startConnect(host, _port, sourceAddress: local);
  final temp = await File(destination).parent.createTemp('.tailnet-update-');
  final partial = File('${temp.path}/package.zip');
  try {
    final request = await client.getUrl(
        Uri(scheme: 'http', host: host.address, port: _port, path: _path));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 10));
    final length = response.contentLength;
    if (response.statusCode != HttpStatus.ok ||
        response.headers.contentType?.mimeType != 'application/zip' ||
        length <= 0 ||
        length > _maxPackageBytes) {
      throw StateError('No published ZIP package at this address');
    }
    var received = 0;
    final output = partial.openWrite();
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        received += chunk.length;
        if (received > length) throw StateError('Package size mismatch');
        output.add(chunk);
        await output.flush();
      }
    } finally {
      await output.close();
    }
    if (received != length || !await _isZip(partial)) {
      throw StateError('Incomplete ZIP package');
    }
    await partial.rename(destination);
  } finally {
    client.close(force: true);
    if (await partial.exists()) await partial.delete();
    await temp.delete();
  }
}

class TailnetUpdateControls extends StatefulWidget {
  const TailnetUpdateControls({super.key});

  @override
  State<TailnetUpdateControls> createState() => _TailnetUpdateControlsState();
}

class _TailnetUpdateControlsState extends State<TailnetUpdateControls> {
  final _server = TailnetPackageServer.instance;
  bool _busy = false;
  String? _status;

  String _text(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final message = await action();
      if (mounted) _status = message;
    } catch (error) {
      if (mounted) _status = _text('操作失败：$error', 'Operation failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _publish() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: _text('选择定制版更新包', 'Choose a custom update package'),
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    await _server.publish(path);
    return null;
  }

  Future<String?> _download() async {
    final host = await showDialog<InternetAddress>(
      context: context,
      builder: (dialog) {
        final form = GlobalKey<FormState>();
        var input = bind.mainGetLocalOption(key: _sourceKey);
        return AlertDialog(
          title: Text(
              _text('从 Tailscale 设备下载定制版', 'Download from a Tailscale device')),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: input,
              onChanged: (value) => input = value,
              decoration: InputDecoration(
                  labelText:
                      _text('发布设备的 Tailscale IP', 'Publisher Tailscale IP')),
              validator: (value) {
                final ip = InternetAddress.tryParse(value?.trim() ?? '');
                return ip != null && isTailnetAddress(ip)
                    ? null
                    : _text(
                        '请输入完整的 Tailscale IP', 'Enter a complete Tailscale IP');
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(translate('Cancel'))),
            FilledButton(
              onPressed: () {
                if (form.currentState?.validate() == true) {
                  Navigator.pop(dialog, InternetAddress.tryParse(input.trim()));
                }
              },
              child: Text(_text('继续', 'Continue')),
            ),
          ],
        );
      },
    );
    if (host == null || !mounted) return null;
    final path = await FilePicker.platform
        .saveFile(fileName: 'RustDeskTailnet-windows-x64.zip');
    if (path == null) return null;
    final destination =
        path.toLowerCase().endsWith('.zip') ? path : '$path.zip';
    await bind.mainSetLocalOption(key: _sourceKey, value: host.address);
    final done = _text('已下载到 $destination', 'Downloaded to $destination');
    await downloadTailnetPackage(host, destination);
    return done;
  }

  @override
  Widget build(BuildContext context) {
    final address = _server.address;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_publish),
                child: Text(_text('发布定制版 ZIP…', 'Publish custom ZIP…')),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_download),
                child: Text(_text('下载定制版…', 'Download custom build…')),
              ),
              if (address != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await _server.stop();
                            return null;
                          }),
                  child: Text(_text('停止分享', 'Stop sharing')),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (address != null) SelectableText(address.toString()),
          if (_status != null) SelectableText(_status!),
        ],
      ),
    );
  }
}
