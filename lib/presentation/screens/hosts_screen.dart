import 'package:flutter/material.dart';

import 'home_screen.dart';

/// Screen displaying the shared hosts panel.
class HostsScreen extends StatelessWidget {
  /// Creates a new [HostsScreen].
  const HostsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SafeArea(bottom: false, child: HostsPanel()));
}
