import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/terminal_theme_service.dart';

/// Screen for creating or editing custom terminal themes.
class ThemeEditorScreen extends ConsumerStatefulWidget {
  /// Creates a new [ThemeEditorScreen].
  const ThemeEditorScreen({this.themeId, super.key});

  /// The theme ID to edit, or null for a new theme.
  final String? themeId;

  @override
  ConsumerState<ThemeEditorScreen> createState() => _ThemeEditorScreenState();
}

class _ThemeEditorScreenState extends ConsumerState<ThemeEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;

  late Color _foreground;
  late Color _background;
  late Color _cursor;
  late Color _selection;

  late Color _black;
  late Color _red;
  late Color _green;
  late Color _yellow;
  late Color _blue;
  late Color _magenta;
  late Color _cyan;
  late Color _white;

  late Color _brightBlack;
  late Color _brightRed;
  late Color _brightGreen;
  late Color _brightYellow;
  late Color _brightBlue;
  late Color _brightMagenta;
  late Color _brightCyan;
  late Color _brightWhite;

  bool _isDark = true;
  bool _isLoading = false;
  TerminalThemeData? _existingTheme;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _initializeFromDefaults();

    if (widget.themeId != null) {
      _loadTheme();
    }
  }

  void _initializeFromDefaults() {
    // Start with Midnight Purple as base
    final base = TerminalThemes.midnightPurple;
    _foreground = base.foreground;
    _background = base.background;
    _cursor = base.cursor;
    _selection = base.selection;
    _black = base.black;
    _red = base.red;
    _green = base.green;
    _yellow = base.yellow;
    _blue = base.blue;
    _magenta = base.magenta;
    _cyan = base.cyan;
    _white = base.white;
    _brightBlack = base.brightBlack;
    _brightRed = base.brightRed;
    _brightGreen = base.brightGreen;
    _brightYellow = base.brightYellow;
    _brightBlue = base.brightBlue;
    _brightMagenta = base.brightMagenta;
    _brightCyan = base.brightCyan;
    _brightWhite = base.brightWhite;
  }

  Future<void> _loadTheme() async {
    setState(() => _isLoading = true);
    final service = ref.read(terminalThemeServiceProvider);
    final theme = await service.getThemeById(widget.themeId!);

    if (theme != null && mounted) {
      setState(() {
        _existingTheme = theme;
        _nameController.text = theme.name;
        _isDark = theme.isDark;
        _foreground = theme.foreground;
        _background = theme.background;
        _cursor = theme.cursor;
        _selection = theme.selection;
        _black = theme.black;
        _red = theme.red;
        _green = theme.green;
        _yellow = theme.yellow;
        _blue = theme.blue;
        _magenta = theme.magenta;
        _cyan = theme.cyan;
        _white = theme.white;
        _brightBlack = theme.brightBlack;
        _brightRed = theme.brightRed;
        _brightGreen = theme.brightGreen;
        _brightYellow = theme.brightYellow;
        _brightBlue = theme.brightBlue;
        _brightMagenta = theme.brightMagenta;
        _brightCyan = theme.brightCyan;
        _brightWhite = theme.brightWhite;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  TerminalThemeData _buildTheme() => TerminalThemeData(
    id: _existingTheme?.id ?? const Uuid().v4(),
    name: _nameController.text.trim(),
    isDark: _isDark,
    isCustom: true,
    foreground: _foreground,
    background: _background,
    cursor: _cursor,
    selection: _selection,
    black: _black,
    red: _red,
    green: _green,
    yellow: _yellow,
    blue: _blue,
    magenta: _magenta,
    cyan: _cyan,
    white: _white,
    brightBlack: _brightBlack,
    brightRed: _brightRed,
    brightGreen: _brightGreen,
    brightYellow: _brightYellow,
    brightBlue: _brightBlue,
    brightMagenta: _brightMagenta,
    brightCyan: _brightCyan,
    brightWhite: _brightWhite,
  );

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.themeId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Theme' : 'Create Theme'),
        actions: [TextButton(onPressed: _saveTheme, child: const Text('Save'))],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Editor panel
                Expanded(
                  flex: 2,
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Theme name
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Theme Name',
                            hintText: 'My Custom Theme',
                          ),
                          validator: (v) =>
                              v?.isEmpty ?? true ? 'Name is required' : null,
                        ),
                        const SizedBox(height: 16),

                        // Dark/Light toggle
                        SwitchListTile(
                          title: const Text('Dark Theme'),
                          subtitle: Text(
                            _isDark ? 'Dark background' : 'Light background',
                          ),
                          value: _isDark,
                          onChanged: (v) => setState(() => _isDark = v),
                        ),
                        const Divider(height: 32),

                        // Special colors section
                        _SectionHeader(title: 'Special Colors'),
                        _ColorRow(
                          label: 'Background',
                          color: _background,
                          onChanged: (c) => setState(() => _background = c),
                        ),
                        _ColorRow(
                          label: 'Foreground',
                          color: _foreground,
                          onChanged: (c) => setState(() => _foreground = c),
                        ),
                        _ColorRow(
                          label: 'Cursor',
                          color: _cursor,
                          onChanged: (c) => setState(() => _cursor = c),
                        ),
                        _ColorRow(
                          label: 'Selection',
                          color: _selection,
                          onChanged: (c) => setState(() => _selection = c),
                        ),
                        const Divider(height: 32),

                        // Standard ANSI colors
                        _SectionHeader(title: 'Standard Colors'),
                        _ColorRow(
                          label: 'Black',
                          color: _black,
                          onChanged: (c) => setState(() => _black = c),
                        ),
                        _ColorRow(
                          label: 'Red',
                          color: _red,
                          onChanged: (c) => setState(() => _red = c),
                        ),
                        _ColorRow(
                          label: 'Green',
                          color: _green,
                          onChanged: (c) => setState(() => _green = c),
                        ),
                        _ColorRow(
                          label: 'Yellow',
                          color: _yellow,
                          onChanged: (c) => setState(() => _yellow = c),
                        ),
                        _ColorRow(
                          label: 'Blue',
                          color: _blue,
                          onChanged: (c) => setState(() => _blue = c),
                        ),
                        _ColorRow(
                          label: 'Magenta',
                          color: _magenta,
                          onChanged: (c) => setState(() => _magenta = c),
                        ),
                        _ColorRow(
                          label: 'Cyan',
                          color: _cyan,
                          onChanged: (c) => setState(() => _cyan = c),
                        ),
                        _ColorRow(
                          label: 'White',
                          color: _white,
                          onChanged: (c) => setState(() => _white = c),
                        ),
                        const Divider(height: 32),

                        // Bright ANSI colors
                        _SectionHeader(title: 'Bright Colors'),
                        _ColorRow(
                          label: 'Bright Black',
                          color: _brightBlack,
                          onChanged: (c) => setState(() => _brightBlack = c),
                        ),
                        _ColorRow(
                          label: 'Bright Red',
                          color: _brightRed,
                          onChanged: (c) => setState(() => _brightRed = c),
                        ),
                        _ColorRow(
                          label: 'Bright Green',
                          color: _brightGreen,
                          onChanged: (c) => setState(() => _brightGreen = c),
                        ),
                        _ColorRow(
                          label: 'Bright Yellow',
                          color: _brightYellow,
                          onChanged: (c) => setState(() => _brightYellow = c),
                        ),
                        _ColorRow(
                          label: 'Bright Blue',
                          color: _brightBlue,
                          onChanged: (c) => setState(() => _brightBlue = c),
                        ),
                        _ColorRow(
                          label: 'Bright Magenta',
                          color: _brightMagenta,
                          onChanged: (c) => setState(() => _brightMagenta = c),
                        ),
                        _ColorRow(
                          label: 'Bright Cyan',
                          color: _brightCyan,
                          onChanged: (c) => setState(() => _brightCyan = c),
                        ),
                        _ColorRow(
                          label: 'Bright White',
                          color: _brightWhite,
                          onChanged: (c) => setState(() => _brightWhite = c),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
                // Preview panel
                Expanded(
                  flex: 1,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: _buildPreview(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildPreview() => Container(
    color: _background,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview',
          style: GoogleFonts.jetBrainsMono(
            color: _foreground,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        _previewLine('user@host', _green, ':', _foreground, '~', _blue),
        _previewText(r'$ ls -la', _foreground),
        _previewText('drwxr-xr-x  5 user  staff   160 Jan 31 12:00 .', _blue),
        _previewText(
          '-rw-r--r--  1 user  staff  1024 Jan 31 12:00 file.txt',
          _foreground,
        ),
        const SizedBox(height: 8),
        _previewLine('user@host', _green, ':', _foreground, '~', _blue),
        _previewText(r'$ echo "Hello World"', _foreground),
        _previewText('Hello World', _yellow),
        const SizedBox(height: 8),
        _previewLine('user@host', _green, ':', _foreground, '~', _blue),
        Row(
          children: [
            _previewText(r'$ ', _foreground),
            Container(width: 8, height: 14, color: _cursor),
          ],
        ),
        const Spacer(),
        // Color swatches
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            _swatch(_black),
            _swatch(_red),
            _swatch(_green),
            _swatch(_yellow),
            _swatch(_blue),
            _swatch(_magenta),
            _swatch(_cyan),
            _swatch(_white),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            _swatch(_brightBlack),
            _swatch(_brightRed),
            _swatch(_brightGreen),
            _swatch(_brightYellow),
            _swatch(_brightBlue),
            _swatch(_brightMagenta),
            _swatch(_brightCyan),
            _swatch(_brightWhite),
          ],
        ),
      ],
    ),
  );

  Widget _previewLine(
    String user,
    Color userColor,
    String sep,
    Color sepColor,
    String path,
    Color pathColor,
  ) => Row(
    children: [
      Text(
        user,
        style: GoogleFonts.jetBrainsMono(color: userColor, fontSize: 11),
      ),
      Text(
        sep,
        style: GoogleFonts.jetBrainsMono(color: sepColor, fontSize: 11),
      ),
      Text(
        path,
        style: GoogleFonts.jetBrainsMono(color: pathColor, fontSize: 11),
      ),
      Text(
        r'$ ',
        style: GoogleFonts.jetBrainsMono(color: sepColor, fontSize: 11),
      ),
    ],
  );

  Widget _previewText(String text, Color color) =>
      Text(text, style: GoogleFonts.jetBrainsMono(color: color, fontSize: 11));

  Widget _swatch(Color color) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(4),
    ),
  );

  Future<void> _saveTheme() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final service = ref.read(terminalThemeServiceProvider);
      final theme = _buildTheme();
      await service.saveCustomTheme(theme);

      ref.invalidate(allTerminalThemesProvider);
      ref.invalidate(customTerminalThemesProvider);

      if (mounted) {
        context.pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Theme "${theme.name}" saved')));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving theme: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: GestureDetector(
      onTap: () => _showColorPicker(context),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
      ),
    ),
  );

  void _showColorPicker(BuildContext context) {
    showDialog<Color>(
      context: context,
      builder: (context) =>
          _SimpleColorPicker(initialColor: color, onColorSelected: onChanged),
    );
  }
}

class _SimpleColorPicker extends StatefulWidget {
  const _SimpleColorPicker({
    required this.initialColor,
    required this.onColorSelected,
  });

  final Color initialColor;
  final ValueChanged<Color> onColorSelected;

  @override
  State<_SimpleColorPicker> createState() => _SimpleColorPickerState();
}

class _SimpleColorPickerState extends State<_SimpleColorPicker> {
  late TextEditingController _hexController;
  late Color _currentColor;

  @override
  void initState() {
    super.initState();
    _currentColor = widget.initialColor;
    _hexController = TextEditingController(text: _colorToHex(_currentColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _colorToHex(Color color) =>
      '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  Color? _hexToColor(String hex) {
    var cleanHex = hex.replaceAll('#', '').replaceAll('0x', '');
    if (cleanHex.length == 6) {
      cleanHex = 'FF$cleanHex';
    }
    if (cleanHex.length != 8) return null;
    final value = int.tryParse(cleanHex, radix: 16);
    return value != null ? Color(value) : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Pick a Color'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Preview
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: _currentColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        const SizedBox(height: 16),
        // Hex input
        TextField(
          controller: _hexController,
          decoration: const InputDecoration(
            labelText: 'Hex Color',
            hintText: '#FF0000',
          ),
          onChanged: (value) {
            final color = _hexToColor(value);
            if (color != null) {
              setState(() => _currentColor = color);
            }
          },
        ),
        const SizedBox(height: 16),
        // Quick presets
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _preset(Colors.red),
            _preset(Colors.green),
            _preset(Colors.blue),
            _preset(Colors.yellow),
            _preset(Colors.purple),
            _preset(Colors.cyan),
            _preset(Colors.orange),
            _preset(Colors.pink),
            _preset(Colors.white),
            _preset(Colors.black),
            _preset(Colors.grey),
          ],
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
          widget.onColorSelected(_currentColor);
          Navigator.pop(context);
        },
        child: const Text('Select'),
      ),
    ],
  );

  Widget _preset(Color color) => GestureDetector(
    onTap: () {
      setState(() {
        _currentColor = color;
        _hexController.text = _colorToHex(color);
      });
    },
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );
}
