import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';

/// Screen for setting up PIN/biometric authentication.
class AuthSetupScreen extends ConsumerStatefulWidget {
  /// Creates a new [AuthSetupScreen].
  const AuthSetupScreen({super.key});

  @override
  ConsumerState<AuthSetupScreen> createState() => _AuthSetupScreenState();
}

class _AuthSetupScreenState extends ConsumerState<AuthSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  int _step = 0; // 0: choose, 1: enter PIN, 2: confirm PIN
  bool _isLoading = false;
  String? _error;
  bool _biometricAvailable = false;
  bool _enableBiometric = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final authService = ref.read(authServiceProvider);
    final available = await authService.isBiometricAvailable();
    setState(() => _biometricAvailable = available);
  }

  Future<void> _setupPin() async {
    if (_pinController.text.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }

    if (_pinController.text != _confirmPinController.text) {
      setState(() => _error = 'PINs do not match');
      _confirmPinController.clear();
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final authService = ref.read(authServiceProvider);
    await authService.setupPin(_pinController.text);

    if (_enableBiometric) {
      await authService.setBiometricEnabled(enabled: true);
    }

    await ref.read(authStateProvider.notifier).refresh();

    setState(() => _isLoading = false);

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  void _skip() {
    ref.read(authStateProvider.notifier).skip();
    Navigator.of(context).pop(false);
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Security Setup'),
        actions: [TextButton(onPressed: _skip, child: const Text('Skip'))],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildStep(theme, colorScheme),
        ),
      ),
    );
  }

  Widget _buildStep(ThemeData theme, ColorScheme colorScheme) {
    switch (_step) {
      case 0:
        return _buildChooseStep(theme, colorScheme);
      case 1:
        return _buildEnterPinStep(theme, colorScheme);
      case 2:
        return _buildConfirmPinStep(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildChooseStep(ThemeData theme, ColorScheme colorScheme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Protect Your Data',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Set up a PIN or use biometrics to secure your SSH credentials.',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      const SizedBox(height: 32),
      _OptionCard(
        icon: Icons.pin_outlined,
        title: 'PIN Code',
        subtitle: 'Use a 4-8 digit PIN',
        onTap: () => setState(() => _step = 1),
      ),
      const SizedBox(height: 12),
      if (_biometricAvailable)
        _OptionCard(
          icon: Icons.fingerprint,
          title: 'Biometrics',
          subtitle: 'Use fingerprint or face recognition',
          trailing: Switch(
            value: _enableBiometric,
            onChanged: (v) => setState(() => _enableBiometric = v),
          ),
          onTap: () => setState(() => _enableBiometric = !_enableBiometric),
        ),
    ],
  );

  Widget _buildEnterPinStep(ThemeData theme, ColorScheme colorScheme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Create PIN',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Enter a 4-8 digit PIN.',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      const SizedBox(height: 32),
      TextField(
        controller: _pinController,
        keyboardType: TextInputType.number,
        obscureText: true,
        maxLength: 8,
        autofocus: true,
        decoration: InputDecoration(labelText: 'PIN', errorText: _error),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (_) {
          if (_pinController.text.length >= 4) {
            setState(() {
              _step = 2;
              _error = null;
            });
          }
        },
      ),
      const SizedBox(height: 24),
      Row(
        children: [
          TextButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('Back'),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: _pinController.text.length >= 4
                ? () => setState(() {
                    _step = 2;
                    _error = null;
                  })
                : null,
            child: const Text('Next'),
          ),
        ],
      ),
    ],
  );

  Widget _buildConfirmPinStep(ThemeData theme, ColorScheme colorScheme) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Confirm PIN',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your PIN again to confirm.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _confirmPinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 8,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Confirm PIN',
              errorText: _error,
            ),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _setupPin(),
          ),
          if (_biometricAvailable) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              value: _enableBiometric,
              onChanged: (v) => setState(() => _enableBiometric = v),
              title: const Text('Enable biometrics'),
              subtitle: const Text('Also allow fingerprint/face unlock'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _step = 1;
                  _error = null;
                }),
                child: const Text('Back'),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: _isLoading ? null : _setupPin,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Complete'),
              ),
            ],
          ),
        ],
      );
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
              if (trailing == null)
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: colorScheme.onSurface.withValues(alpha: 0.4),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
