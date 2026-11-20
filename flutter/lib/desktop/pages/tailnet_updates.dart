import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'tailnet_local.dart';

const _port = 21120;
const _path = '/rustdesk-tailnet.zip';
const _publisherIp = String.fromEnvironment('TAILNET_UPDATE_PUBLISHER');
const _releaseZip = String.fromEnvironment('TAILNET_RELEASE_ZIP');
const _releaseName = 'RustDeskTailnet-windows-x64.zip';

final _publisher = _configuredPublisher();

InternetAddress? _configuredPublisher() {
  final ip = InternetAddress.tryParse(_publisherIp);
  return ip != null && isTailnetAddress(ip) ? ip : null;
}

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
  bool _isPublisher = false;

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

  Future<void> start() async {
    final publisher = _publisher;
    if (publisher == null || _releaseZip.isEmpty || _server != null) return;
    try {
      final status = await readTailnetStatus();
      final local = tailnetAddresses(status['Self']?['TailscaleIPs']);
      if (status['BackendState'] != 'Running' || !local.contains(publisher)) {
        return;
      }
      _isPublisher = true;
      final server = await HttpServer.bind(publisher, _port);
      server.idleTimeout = const Duration(seconds: 15);
      _server = server;
      server.listen(_serve);
    } catch (error) {
      debugPrint('Could not start Tailnet update sharing: $error');
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final peer = request.connectionInfo?.remoteAddress;
    final file = File(_releaseZip);
    if (request.method != 'GET' ||
        request.uri.path != _path ||
        peer == null ||
        !isTailnetAddress(peer)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    try {
      final entry = await file.stat();
      if (entry.type != FileSystemEntityType.file ||
          entry.size > _maxPackageBytes ||
          !await _isZip(file)) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.headers.contentType = ContentType('application', 'zip');
        response.headers
            .set('Content-Disposition', 'attachment; filename="$_releaseName"');
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.contentLength = entry.size;
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

Future<void> _downloadTailnetPackage(
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
    throw StateError('The update publisher is unavailable on Tailscale');
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

  Future<String?> _download(InternetAddress host) async {
    final path = await FilePicker.platform.saveFile(fileName: _releaseName);
    if (path == null || !mounted) return null;
    final destination =
        path.toLowerCase().endsWith('.zip') ? path : '$path.zip';
    final done = _text('已下载到 $destination', 'Downloaded to $destination');
    await _downloadTailnetPackage(host, destination);
    return done;
  }

  @override
  Widget build(BuildContext context) {
    final host = _publisher;
    if (host == null) return const SizedBox.shrink();
    final address = _server.address;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: [
          if (_server._isPublisher) ...[
            if (address != null) ...[
              SelectableText(address.toString()),
              Text(_text('项目 releases 文件夹中的 ZIP 会直接用于下载。',
                  'Downloads use the ZIP in the project releases folder.')),
            ] else
              Text(_text(
                  '本机的更新服务启动失败。', 'The update publisher could not start.')),
          ] else
            OutlinedButton(
              onPressed: _busy ? null : () => _run(() => _download(host)),
              child: Text(_text('下载定制版…', 'Download custom build…')),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_status != null) SelectableText(_status!),
        ],
      ),
    );
  }
}
