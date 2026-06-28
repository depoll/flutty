import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../app/theme.dart';
import '../../domain/services/port_forward_browser_service.dart';

/// Initial tab configuration for the embedded browser.
class PortForwardBrowserInitialTab {
  /// Creates an initial browser tab.
  const PortForwardBrowserInitialTab({required this.uri, this.title});

  /// URL loaded by the tab.
  final Uri uri;

  /// Optional label shown until the page title is available.
  final String? title;
}

/// Launch configuration for the embedded port-forward browser.
class PortForwardBrowserLaunch {
  /// Creates browser launch configuration.
  const PortForwardBrowserLaunch({required this.tabs, this.selectedIndex = 0})
    : assert(tabs.length > 0),
      assert(selectedIndex >= 0),
      assert(selectedIndex < tabs.length);

  /// Initial browser tabs.
  final List<PortForwardBrowserInitialTab> tabs;

  /// Initially selected tab.
  final int selectedIndex;
}

/// Embedded browser for pages exposed through local port forwards.
class PortForwardBrowserScreen extends StatefulWidget {
  /// Creates a port-forward browser screen.
  const PortForwardBrowserScreen({
    required this.initialTabs,
    this.initialTabIndex = 0,
    super.key,
  }) : assert(initialTabs.length > 0),
       assert(initialTabIndex >= 0),
       assert(initialTabIndex < initialTabs.length);

  /// Initial tabs to open.
  final List<PortForwardBrowserInitialTab> initialTabs;

  /// Initially selected tab.
  final int initialTabIndex;

  @override
  State<PortForwardBrowserScreen> createState() =>
      _PortForwardBrowserScreenState();
}

class _PortForwardBrowserScreenState extends State<PortForwardBrowserScreen> {
  TextEditingController? _addressController;
  List<_PortForwardBrowserTabState> _tabs = [];
  final _addressFocusNode = FocusNode();

  var _selectedTabIndex = 0;
  var _nextTabId = 0;
  var _allowRoutePop = false;

  _PortForwardBrowserTabState get _selectedTab => _tabs[_selectedTabIndex];

  @override
  void initState() {
    super.initState();
    _addressFocusNode.addListener(_handleAddressFocusChanged);
    unawaited(_initializeBrowser());
  }

  @override
  void dispose() {
    _addressFocusNode.removeListener(_handleAddressFocusChanged);
    _addressController?.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_addressController == null || _tabs.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final selectedTab = _selectedTab;
    return PopScope(
      canPop:
          _allowRoutePop ||
          (!_addressFocusNode.hasFocus && !selectedTab.canGoBack),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _allowRoutePop) {
          return;
        }
        unawaited(_handleRouteBack());
      },
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: _buildBrowserViewport(
                Stack(
                  children: [
                    Positioned.fill(
                      child: WebViewWidget(
                        key: ValueKey<int>(selectedTab.id),
                        controller: selectedTab.controller,
                      ),
                    ),
                    if (selectedTab.isLoading && selectedTab.progress < 100)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          value: selectedTab.progress / 100,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _buildBottomChrome(context, selectedTab),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowserViewport(Widget child) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return child;
    }

    return SafeArea(left: false, right: false, bottom: false, child: child);
  }

  _PortForwardBrowserTabState _createTab(PortForwardBrowserInitialTab seed) {
    final initialUri = normalizePortForwardBrowserUri(seed.uri);
    late final _PortForwardBrowserTabState tab;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              _handleNavigationRequest(tab, request),
          onProgress: (progress) => _handleProgress(tab, progress),
          onPageStarted: (url) => _handlePageStarted(tab, url),
          onPageFinished: (url) => unawaited(_handlePageFinished(tab, url)),
          onUrlChange: (change) => _handleUrlChange(tab, change.url),
        ),
      );

    return tab = _PortForwardBrowserTabState(
      id: _nextTabId++,
      controller: controller,
      currentUri: initialUri,
      initialTitle: seed.title,
    );
  }

  Future<void> _initializeBrowser() async {
    final tabs = widget.initialTabs.map(_createTab).toList(growable: true);
    final selectedTabIndex = widget.initialTabIndex;
    final addressController = TextEditingController(
      text: tabs[selectedTabIndex].currentUri.toString(),
    );
    setState(() {
      _tabs = tabs;
      _selectedTabIndex = selectedTabIndex;
      _addressController = addressController;
    });
    _scheduleSelectedTabLoad();
  }

  void _scheduleSelectedTabLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_ensureTabLoaded(_selectedTab));
    });
  }

  Future<void> _ensureTabLoaded(_PortForwardBrowserTabState tab) async {
    if (tab.hasStartedLoading || !_tabs.contains(tab)) {
      return;
    }
    tab.hasStartedLoading = true;
    await _configureAndLoadController(tab.controller, tab.currentUri);
  }

  Future<void> _configureAndLoadController(
    WebViewController controller,
    Uri initialUri,
  ) async {
    await controller.enableZoom(false);
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      await platformController.setUseWideViewPort(true);
      await platformController.setTextZoom(100);
      await platformController.setInsetsForWebContentToIgnore([
        AndroidWebViewInsets.navigationBars,
        AndroidWebViewInsets.mandatorySystemGestures,
        AndroidWebViewInsets.systemGestures,
        AndroidWebViewInsets.tappableElement,
      ]);
    }
    await controller.loadRequest(initialUri);
  }

  Widget _buildBottomChrome(
    BuildContext context,
    _PortForwardBrowserTabState selectedTab,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_tabs.length > 1) _buildTabStrip(context),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: _buildBottomControls(context, selectedTab),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    _PortForwardBrowserTabState selectedTab,
  ) {
    final isEditingAddress = _addressFocusNode.hasFocus;
    if (isEditingAddress) {
      return _buildAddressField(context);
    }

    return Row(
      children: [
        IconButton(
          onPressed: _closeBrowserRoute,
          tooltip: 'Close',
          icon: const Icon(Icons.close),
        ),
        const SizedBox(width: 4),
        Expanded(child: _buildAddressField(context)),
        const SizedBox(width: 4),
        IconButton(
          onPressed: selectedTab.canGoBack ? () => unawaited(_goBack()) : null,
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          onPressed: selectedTab.canGoForward
              ? () => unawaited(_goForward())
              : null,
          tooltip: 'Forward',
          icon: const Icon(Icons.arrow_forward),
        ),
        IconButton(
          onPressed: () => unawaited(selectedTab.controller.reload()),
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          onPressed: () => unawaited(_openCurrentPageInSystemBrowser()),
          tooltip: 'Open in system browser',
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }

  Widget _buildAddressField(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return TextField(
      controller: _addressController,
      focusNode: _addressFocusNode,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      style: FluttyTheme.monoStyle.copyWith(
        fontSize: 13,
        color: colorScheme.onSurface,
      ),
      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        hintText: 'Search or enter URL',
        prefixIcon: const Icon(Icons.travel_explore),
        suffixIcon: IconButton(
          onPressed: () => unawaited(_loadAddress(_addressController!.text)),
          tooltip: 'Load URL',
          icon: const Icon(Icons.arrow_circle_right_outlined),
        ),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onTapOutside: (_) => _addressFocusNode.unfocus(),
      onSubmitted: (value) => unawaited(_loadAddress(value)),
    );
  }

  void _handleAddressFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildTabStrip(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SizedBox(
        height: 48,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          scrollDirection: Axis.horizontal,
          itemCount: _tabs.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final tab = _tabs[index];
            final selected = index == _selectedTabIndex;
            return InputChip(
              selected: selected,
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  _tabLabel(tab),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              avatar: Icon(
                Icons.language,
                size: 18,
                color: selected ? colorScheme.onSecondaryContainer : null,
              ),
              onPressed: () => _selectTab(index),
              onDeleted: _tabs.length > 1 ? () => _closeTab(index) : null,
            );
          },
        ),
      ),
    );
  }

  String _tabLabel(_PortForwardBrowserTabState tab) {
    if (tab.pageTitle?.trim().isNotEmpty ?? false) {
      return tab.pageTitle!.trim();
    }
    if (tab.initialTitle?.trim().isNotEmpty ?? false) {
      return tab.initialTitle!.trim();
    }
    return tab.currentUri.authority.isNotEmpty
        ? tab.currentUri.authority
        : tab.currentUri.toString();
  }

  void _selectTab(int index) {
    if (index == _selectedTabIndex) {
      return;
    }
    setState(() {
      _selectedTabIndex = index;
      _addressController?.text = _selectedTab.currentUri.toString();
    });
    _scheduleSelectedTabLoad();
    unawaited(_refreshNavigationState(_selectedTab));
  }

  void _closeTab(int index) {
    if (_tabs.length == 1) {
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_selectedTabIndex >= _tabs.length) {
        _selectedTabIndex = _tabs.length - 1;
      } else if (index < _selectedTabIndex) {
        _selectedTabIndex -= 1;
      }
      _addressController?.text = _selectedTab.currentUri.toString();
    });
  }

  void _handleProgress(_PortForwardBrowserTabState tab, int progress) {
    if (!mounted) return;
    setState(() {
      tab
        ..progress = progress
        ..isLoading = progress < 100;
    });
  }

  void _handlePageStarted(_PortForwardBrowserTabState tab, String url) {
    if (!mounted) return;
    final uri = Uri.tryParse(url);
    setState(() {
      tab.isLoading = true;
      if (uri != null) {
        tab.currentUri = _normalizeLoadedBrowserUri(uri);
      }
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
  }

  void _handleUrlChange(_PortForwardBrowserTabState tab, String? url) {
    if (!mounted || url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    setState(() {
      tab.currentUri = _normalizeLoadedBrowserUri(uri);
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
    unawaited(_refreshNavigationState(tab));
  }

  Future<void> _handlePageFinished(
    _PortForwardBrowserTabState tab,
    String url,
  ) async {
    final title = await tab.controller.getTitle();
    if (!mounted) return;
    final uri = Uri.tryParse(url);
    setState(() {
      tab
        ..isLoading = false
        ..pageTitle = title;
      if (uri != null) {
        tab.currentUri = _normalizeLoadedBrowserUri(uri);
      }
      if (identical(tab, _selectedTab) && !_addressFocusNode.hasFocus) {
        _addressController?.text = tab.currentUri.toString();
      }
    });
    await _refreshNavigationState(tab);
  }

  Future<void> _goBack() async {
    final tab = _selectedTab;
    await tab.controller.goBack();
    await _refreshNavigationState(tab);
  }

  Future<void> _handleRouteBack() async {
    if (_addressFocusNode.hasFocus) {
      _addressFocusNode.unfocus();
      return;
    }

    final tab = _selectedTab;
    final canGoBack = await tab.controller.canGoBack();
    if (!mounted || !_tabs.contains(tab)) {
      return;
    }

    if (canGoBack) {
      await tab.controller.goBack();
      await _refreshNavigationState(tab);
      return;
    }

    _closeBrowserRoute();
  }

  void _closeBrowserRoute() {
    if (_allowRoutePop) {
      return;
    }
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        unawaited(navigator.maybePop());
      }
    });
  }

  Future<void> _goForward() async {
    final tab = _selectedTab;
    await tab.controller.goForward();
    await _refreshNavigationState(tab);
  }

  Future<void> _loadAddress(String address) async {
    final uri = _parseBrowserAddress(address);
    if (uri == null) {
      _showMessage('Enter an HTTP or HTTPS URL');
      return;
    }

    _addressFocusNode.unfocus();
    final tab = _selectedTab;
    await tab.controller.loadRequest(uri);
    if (!mounted) return;
    setState(() {
      tab.currentUri = uri;
      _addressController?.text = uri.toString();
    });
  }

  Future<void> _openCurrentPageInSystemBrowser() async {
    final currentUrl = await _selectedTab.controller.currentUrl();
    if (!mounted) return;

    final uri = Uri.tryParse(currentUrl ?? '') ?? _selectedTab.currentUri;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      _showMessage('Only HTTP and HTTPS pages can open in the system browser');
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (!mounted || launched) {
      return;
    }
    _showMessage('Could not open $uri');
  }

  NavigationDecision _handleNavigationRequest(
    _PortForwardBrowserTabState tab,
    NavigationRequest request,
  ) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) {
      _showMessage('Could not open ${request.url}');
      return NavigationDecision.prevent;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final normalizedUri = normalizePortForwardBrowserUri(uri);
      if (normalizedUri.toString() != uri.toString()) {
        unawaited(tab.controller.loadRequest(normalizedUri));
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }
    if (uri.scheme == 'about' || uri.scheme == 'blob' || uri.scheme == 'data') {
      return NavigationDecision.navigate;
    }

    _showMessage('Unsupported link scheme: ${uri.scheme}');
    return NavigationDecision.prevent;
  }

  Future<void> _refreshNavigationState(_PortForwardBrowserTabState tab) async {
    final canGoBack = await tab.controller.canGoBack();
    final canGoForward = await tab.controller.canGoForward();
    if (!mounted) return;
    setState(() {
      tab
        ..canGoBack = canGoBack
        ..canGoForward = canGoForward;
    });
  }

  Uri? _parseBrowserAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final candidate = _hasUriScheme(trimmed)
        ? trimmed
        : '${_defaultSchemeForAddress(trimmed)}://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    return normalizePortForwardBrowserUri(uri);
  }

  Uri _normalizeLoadedBrowserUri(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https'
      ? normalizePortForwardBrowserUri(uri)
      : uri;

  String _defaultSchemeForAddress(String address) {
    final candidate = Uri.tryParse('//$address');
    return candidate != null && isPortForwardBrowserHost(candidate.host)
        ? 'http'
        : 'https';
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

class _PortForwardBrowserTabState {
  _PortForwardBrowserTabState({
    required this.id,
    required this.controller,
    required this.currentUri,
    this.initialTitle,
  });

  final int id;
  final WebViewController controller;
  final String? initialTitle;
  int progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool isLoading = true;
  bool hasStartedLoading = false;
  Uri currentUri;
  String? pageTitle;
}
