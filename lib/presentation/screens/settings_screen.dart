import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../domain/models/terminal_themes.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/settings_service.dart';
import '../widgets/terminal_theme_picker.dart';

/// Settings screen with appearance, security, terminal, and about sections.
class SettingsScreen extends ConsumerWidget {
  /// Creates a new [SettingsScreen].
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: const [
        _AppearanceSection(),
        _SecuritySection(),
        _TerminalSection(),
        _AboutSection(),
      ],
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeNotifierProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Appearance'),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Theme'),
          subtitle: Text(_themeModeLabel(themeMode)),
          onTap: () => _showThemeDialog(context, ref, themeMode),
        ),
      ],
    );
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
    ThemeMode.system => 'System default',
  };

  void _showThemeDialog(
    BuildContext context,
    WidgetRef ref,
    ThemeMode current,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Theme'),
        content: RadioGroup<ThemeMode>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(themeModeNotifierProvider.notifier).setThemeMode(value);
              Navigator.pop(context);
            }
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ThemeMode>(
                title: Text('System default'),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Light'),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Dark'),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecuritySection extends ConsumerWidget {
  const _SecuritySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final isAuthEnabled = authState != AuthState.notConfigured;
    final autoLockTimeout = ref.watch(autoLockTimeoutNotifierProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Security'),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('Change PIN'),
          subtitle: Text(
            isAuthEnabled ? 'Update your PIN code' : 'PIN not set',
          ),
          enabled: isAuthEnabled,
          onTap: isAuthEnabled
              ? () => _showChangePinDialog(context, ref)
              : null,
        ),
        FutureBuilder<bool>(
          future: ref.read(authServiceProvider).isBiometricAvailable(),
          builder: (context, snapshot) {
            final isAvailable = snapshot.data ?? false;
            return FutureBuilder<bool>(
              future: ref.read(authServiceProvider).isBiometricEnabled(),
              builder: (context, enabledSnapshot) {
                final isEnabled = enabledSnapshot.data ?? false;
                return SwitchListTile(
                  secondary: const Icon(Icons.fingerprint),
                  title: const Text('Biometric authentication'),
                  subtitle: Text(
                    isAvailable
                        ? 'Use fingerprint or face to unlock'
                        : 'Not available on this device',
                  ),
                  value: isEnabled && isAvailable,
                  onChanged: isAvailable && isAuthEnabled
                      ? (value) => _toggleBiometric(ref, value)
                      : null,
                );
              },
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Auto-lock timeout'),
          subtitle: Text(
            autoLockTimeout == 0
                ? 'Disabled'
                : '$autoLockTimeout minute${autoLockTimeout == 1 ? '' : 's'}',
          ),
          enabled: isAuthEnabled,
          onTap: isAuthEnabled
              ? () => _showAutoLockDialog(context, ref, autoLockTimeout)
              : null,
        ),
      ],
    );
  }

  void _showChangePinDialog(BuildContext context, WidgetRef ref) {
    final currentPinController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change PIN'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: currentPinController,
                decoration: const InputDecoration(labelText: 'Current PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                validator: (v) => v?.isEmpty ?? true ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: newPinController,
                decoration: const InputDecoration(labelText: 'New PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v?.isEmpty ?? true) return 'Required';
                  if (v!.length < 4) return 'PIN must be at least 4 digits';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: confirmPinController,
                decoration: const InputDecoration(labelText: 'Confirm new PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v != newPinController.text) return 'PINs do not match';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState?.validate() ?? false) {
                final success = await ref
                    .read(authServiceProvider)
                    .changePin(
                      currentPinController.text,
                      newPinController.text,
                    );
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        success
                            ? 'PIN changed successfully'
                            : 'Current PIN is incorrect',
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBiometric(WidgetRef ref, bool value) async {
    await ref.read(authServiceProvider).setBiometricEnabled(enabled: value);
    ref.invalidate(authStateProvider);
  }

  void _showAutoLockDialog(BuildContext context, WidgetRef ref, int current) {
    final options = [0, 1, 2, 5, 10, 15, 30];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Auto-lock timeout'),
        content: RadioGroup<int>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref
                  .read(autoLockTimeoutNotifierProvider.notifier)
                  .setTimeout(value);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map(
                  (minutes) => RadioListTile<int>(
                    title: Text(
                      minutes == 0
                          ? 'Disabled'
                          : '$minutes minute${minutes == 1 ? '' : 's'}',
                    ),
                    value: minutes,
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _TerminalSection extends ConsumerWidget {
  const _TerminalSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontSize = ref.watch(fontSizeNotifierProvider);
    final fontFamily = ref.watch(fontFamilyNotifierProvider);
    final cursorStyle = ref.watch(cursorStyleNotifierProvider);
    final bellSound = ref.watch(bellSoundNotifierProvider);
    final themeSettings = ref.watch(terminalThemeSettingsProvider);

    final lightTheme = TerminalThemes.getById(themeSettings.lightThemeId);
    final darkTheme = TerminalThemes.getById(themeSettings.darkThemeId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Terminal'),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Light Mode Theme'),
          subtitle: Text(lightTheme?.name ?? 'Default'),
          onTap: () => _showThemePicker(context, ref, isLight: true),
        ),
        ListTile(
          leading: const Icon(Icons.palette),
          title: const Text('Dark Mode Theme'),
          subtitle: Text(darkTheme?.name ?? 'Default'),
          onTap: () => _showThemePicker(context, ref, isLight: false),
        ),
        ListTile(
          leading: const Icon(Icons.format_size),
          title: const Text('Font size'),
          subtitle: Text('${fontSize.round()} pt'),
          onTap: () => _showFontSizeDialog(context, ref, fontSize),
        ),
        ListTile(
          leading: const Icon(Icons.font_download_outlined),
          title: const Text('Font family'),
          subtitle: Text(_fontFamilyLabel(fontFamily)),
          onTap: () => _showFontFamilyDialog(context, ref, fontFamily),
        ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('Cursor style'),
          subtitle: Text(_cursorStyleLabel(cursorStyle)),
          onTap: () => _showCursorStyleDialog(context, ref, cursorStyle),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_outlined),
          title: const Text('Bell sound'),
          subtitle: const Text('Play sound on terminal bell'),
          value: bellSound,
          onChanged: (value) {
            ref
                .read(bellSoundNotifierProvider.notifier)
                .setEnabled(enabled: value);
          },
        ),
      ],
    );
  }

  Future<void> _showThemePicker(
    BuildContext context,
    WidgetRef ref, {
    required bool isLight,
  }) async {
    final settings = ref.read(terminalThemeSettingsProvider);
    final currentId = isLight ? settings.lightThemeId : settings.darkThemeId;

    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null) {
      final notifier = ref.read(terminalThemeSettingsProvider.notifier);
      if (isLight) {
        await notifier.setLightTheme(theme.id);
      } else {
        await notifier.setDarkTheme(theme.id);
      }
    }
  }

  String _fontFamilyLabel(String family) => switch (family) {
    'monospace' => 'System Monospace',
    'JetBrains Mono' => 'JetBrains Mono',
    'Fira Code' => 'Fira Code',
    'Source Code Pro' => 'Source Code Pro',
    'Ubuntu Mono' => 'Ubuntu Mono',
    'Roboto Mono' => 'Roboto Mono',
    'IBM Plex Mono' => 'IBM Plex Mono',
    'Inconsolata' => 'Inconsolata',
    'Anonymous Pro' => 'Anonymous Pro',
    'Cousine' => 'Cousine',
    'PT Mono' => 'PT Mono',
    'Space Mono' => 'Space Mono',
    'VT323' => 'VT323 (Retro)',
    'Share Tech Mono' => 'Share Tech Mono',
    'Overpass Mono' => 'Overpass Mono',
    'Oxygen Mono' => 'Oxygen Mono',
    _ => family,
  };

  /// Gets a TextStyle for the given font family using Google Fonts.
  TextStyle _getFontStyle(String family, {double fontSize = 16}) =>
      switch (family) {
        'monospace' => TextStyle(fontFamily: 'monospace', fontSize: fontSize),
        'JetBrains Mono' => GoogleFonts.jetBrainsMono(fontSize: fontSize),
        'Fira Code' => GoogleFonts.firaCode(fontSize: fontSize),
        'Source Code Pro' => GoogleFonts.sourceCodePro(fontSize: fontSize),
        'Ubuntu Mono' => GoogleFonts.ubuntuMono(fontSize: fontSize),
        'Roboto Mono' => GoogleFonts.robotoMono(fontSize: fontSize),
        'IBM Plex Mono' => GoogleFonts.ibmPlexMono(fontSize: fontSize),
        'Inconsolata' => GoogleFonts.inconsolata(fontSize: fontSize),
        'Anonymous Pro' => GoogleFonts.anonymousPro(fontSize: fontSize),
        'Cousine' => GoogleFonts.cousine(fontSize: fontSize),
        'PT Mono' => GoogleFonts.ptMono(fontSize: fontSize),
        'Space Mono' => GoogleFonts.spaceMono(fontSize: fontSize),
        'VT323' => GoogleFonts.vt323(fontSize: fontSize),
        'Share Tech Mono' => GoogleFonts.shareTechMono(fontSize: fontSize),
        'Overpass Mono' => GoogleFonts.overpassMono(fontSize: fontSize),
        'Oxygen Mono' => GoogleFonts.oxygenMono(fontSize: fontSize),
        _ => TextStyle(fontFamily: family, fontSize: fontSize),
      };

  String _cursorStyleLabel(String style) => switch (style) {
    'block' => 'Block',
    'underline' => 'Underline',
    'bar' => 'Bar',
    _ => style,
  };

  void _showFontSizeDialog(
    BuildContext context,
    WidgetRef ref,
    double current,
  ) {
    var tempValue = current;
    final currentFont = ref.read(fontFamilyNotifierProvider);
    const previewText = 'AaBbCc 0123 {}[]';

    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Font size'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Live preview with current font
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      previewText,
                      style: _getFontStyle(
                        currentFont,
                      ).copyWith(fontSize: tempValue),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${tempValue.round()} pt',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Slider(
                value: tempValue,
                min: 8,
                max: 24,
                divisions: 16,
                label: '${tempValue.round()} pt',
                onChanged: (value) => setState(() => tempValue = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(fontSizeNotifierProvider.notifier)
                    .setFontSize(tempValue);
                Navigator.pop(context);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  void _showFontFamilyDialog(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    final options = [
      'monospace',
      'JetBrains Mono',
      'Fira Code',
      'Source Code Pro',
      'Ubuntu Mono',
      'Roboto Mono',
      'IBM Plex Mono',
      'Inconsolata',
      'Anonymous Pro',
      'Cousine',
      'PT Mono',
      'Space Mono',
      'VT323',
      'Share Tech Mono',
      'Overpass Mono',
      'Oxygen Mono',
    ];
    const previewText = 'AaBbCc 0123 {}[]';

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Font family'),
        content: SizedBox(
          width: double.maxFinite,
          height: 450,
          child: Column(
            children: [
              // Current selection preview
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withAlpha(50),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withAlpha(100),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Currently Selected',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            _fontFamilyLabel(current),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(previewText, style: _getFontStyle(current)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Font list
              Expanded(
                child: RadioGroup<String>(
                  groupValue: current,
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(fontFamilyNotifierProvider.notifier)
                          .setFontFamily(value);
                      Navigator.pop(context);
                    }
                  },
                  child: ListView.builder(
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final family = options[index];
                      return RadioListTile<String>(
                        title: Text(_fontFamilyLabel(family)),
                        subtitle: Text(
                          previewText,
                          style: _getFontStyle(family),
                        ),
                        value: family,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCursorStyleDialog(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    final options = ['block', 'underline', 'bar'];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cursor style'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref
                  .read(cursorStyleNotifierProvider.notifier)
                  .setCursorStyle(value);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map(
                  (style) => RadioListTile<String>(
                    title: Text(_cursorStyleLabel(style)),
                    value: style,
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionHeader(title: 'About'),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('App version'),
        subtitle: Text('0.1.0'),
      ),
      ListTile(
        leading: const Icon(Icons.code),
        title: const Text('GitHub'),
        subtitle: const Text('View source code'),
        onTap: () => _showGitHubInfo(context),
      ),
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: const Text('Licenses'),
        subtitle: const Text('Open source licenses'),
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'Flutty',
          applicationVersion: '0.1.0',
        ),
      ),
    ],
  );

  void _showGitHubInfo(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('GitHub: github.com/flutty-app/flutty')),
    );
  }
}
