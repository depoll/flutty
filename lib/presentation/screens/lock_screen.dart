import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';

/// Lock screen for PIN/biometric authentication.
class LockScreen extends ConsumerStatefulWidget {
  /// Creates a new [LockScreen].
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pinController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _error;
  bool _showPin = false;
  AuthMethod _authMethod = AuthMethod.none;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAuthMethod());
  }

  Future<void> _checkAuthMethod() async {
    final authService = ref.read(authServiceProvider);
    final method = await authService.getAuthMethod();
    setState(() => _authMethod = method);

    // Auto-trigger biometric if available
    if (method == AuthMethod.biometric || method == AuthMethod.both) {
      unawaited(_authenticateWithBiometrics());
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final success = await ref
        .read(authStateProvider.notifier)
        .unlockWithBiometrics();

    setState(() => _isLoading = false);

    if (!success && mounted) {
      setState(() => _error = 'Biometric authentication failed');
    }
  }

  Future<void> _authenticateWithPin() async {
    if (_pinController.text.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final success = await ref
        .read(authStateProvider.notifier)
        .unlockWithPin(_pinController.text);

    setState(() => _isLoading = false);

    if (!success && mounted) {
      setState(() => _error = 'Incorrect PIN');
      _pinController.clear();
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo/icon
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.terminal,
                  size: 64,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Flutty',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your PIN to unlock',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 48),

              // PIN input
              if (_authMethod == AuthMethod.pin ||
                  _authMethod == AuthMethod.both) ...[
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _pinController,
                    focusNode: _focusNode,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    obscureText: !_showPin,
                    maxLength: 8,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      letterSpacing: 8,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '••••',
                      errorText: _error,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showPin ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _showPin = !_showPin),
                      ),
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _authenticateWithPin(),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 200,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _authenticateWithPin,
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Unlock'),
                  ),
                ),
              ],

              // Biometric button
              if (_authMethod == AuthMethod.biometric ||
                  _authMethod == AuthMethod.both) ...[
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: _isLoading ? null : _authenticateWithBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Use biometrics'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
