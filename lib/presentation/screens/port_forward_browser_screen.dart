import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../domain/services/port_forward_browser_service.dart';

/// Embedded browser for pages exposed through local port forwards.
class PortForwardBrowserScreen extends StatefulWidget {
  /// Creates a port-forward browser screen.
  const PortForwardBrowserScreen({
    required this.initialUri,
    required this.allowedPort,
    this.title,
    super.key,
  }) : assert(allowedPort > 0 && allowedPort <= 65535);

  /// Initial URL to load.
  final Uri initialUri;

  /// Local forwarded port this browser is allowed to load.
  final int allowedPort;

  /// Optional title shown before the page title is available.
  final String? title;

  @override
  State<PortForwardBrowserScreen> createState() =>
      _PortForwardBrowserScreenState();
}

class _PortForwardBrowserScreenState extends State<PortForwardBrowserScreen> {
  late final WebViewController _controller;
  late final TextEditingController _addressController;
  final _addressFocusNode = FocusNode();

  var _progress = 0;
  var _canGoBack = false;
  var _canGoForward = false;
  var _isLoading = true;
  String? _pageTitle;

  @override
  void initState() {
    super.initState();
    final initialUri = normalizePortForwardBrowserUri(widget.initialUri);
    _addressController = TextEditingController(text: initialUri.toString());
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onProgress: _handleProgress,
          onPageStarted: _handlePageStarted,
          onPageFinished: (url) => unawaited(_handlePageFinished(url)),
        ),
      );
    unawaited(_controller.loadRequest(initialUri));
  }

  @override
  void dispose() {
    _addressController.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_pageTitle?.isNotEmpty ?? false ? _pageTitle! : _title),
      actions: [
        IconButton(
          onPressed: _canGoBack ? () => unawaited(_goBack()) : null,
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          onPressed: _canGoForward ? () => unawaited(_goForward()) : null,
          tooltip: 'Forward',
          icon: const Icon(Icons.arrow_forward),
        ),
        IconButton(
          onPressed: () => unawaited(_controller.reload()),
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_isLoading && _progress < 100)
          LinearProgressIndicator(value: _progress / 100),
        _buildAddressBar(context),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    ),
  );

  String get _title => widget.title?.isNotEmpty ?? false
      ? widget.title!
      : 'Port Forward Browser';

  Widget _buildAddressBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          controller: _addressController,
          focusNode: _addressFocusNode,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.travel_explore),
            suffixIcon: IconButton(
              onPressed: () => unawaited(_loadAddress(_addressController.text)),
              tooltip: 'Load URL',
              icon: const Icon(Icons.arrow_circle_right_outlined),
            ),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => unawaited(_loadAddress(value)),
        ),
      ),
    );
  }

  void _handleProgress(int progress) {
    if (!mounted) return;
    setState(() {
      _progress = progress;
      _isLoading = progress < 100;
    });
  }

  void _handlePageStarted(String url) {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _addressController.text = url;
    });
  }

  Future<void> _handlePageFinished(String url) async {
    final title = await _controller.getTitle();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _pageTitle = title;
      _addressController.text = url;
    });
    await _refreshNavigationState();
  }

  Future<void> _goBack() async {
    await _controller.goBack();
    await _refreshNavigationState();
  }

  Future<void> _goForward() async {
    await _controller.goForward();
    await _refreshNavigationState();
  }

  Future<void> _loadAddress(String address) async {
    final uri = _parseBrowserAddress(address);
    if (uri == null) {
      _showMessage('Enter a localhost URL for port ${widget.allowedPort}');
      return;
    }

    _addressFocusNode.unfocus();
    await _controller.loadRequest(uri);
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final normalizedUri = uri == null
        ? null
        : normalizePortForwardBrowserUri(uri);
    if (normalizedUri == null ||
        !isPortForwardBrowserUri(normalizedUri, port: widget.allowedPort)) {
      _showMessage('Blocked navigation outside this port forward');
      return NavigationDecision.prevent;
    }
    if (normalizedUri.toString() != uri.toString()) {
      unawaited(_controller.loadRequest(normalizedUri));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _refreshNavigationState() async {
    final canGoBack = await _controller.canGoBack();
    final canGoForward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  Uri? _parseBrowserAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final candidate = _hasUriScheme(trimmed) ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    final normalizedUri = normalizePortForwardBrowserUri(uri);
    if (!isPortForwardBrowserUri(normalizedUri, port: widget.allowedPort)) {
      return null;
    }
    return normalizedUri;
  }

  bool _hasUriScheme(String value) =>
      RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
