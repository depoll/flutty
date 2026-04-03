import 'package:flutter/material.dart';

import 'home_screen.dart';

/// Screen displaying the shared snippets panel.
class SnippetsScreen extends StatelessWidget {
  /// Creates a new [SnippetsScreen].
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SafeArea(bottom: false, child: SnippetsPanel()));
}
