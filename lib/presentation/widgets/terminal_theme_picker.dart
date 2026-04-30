import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../domain/models/iterm_color_scheme.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/iterm_color_scheme_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import 'theme_preview_card.dart';

const _liveThemeSearchMinLength = 2;
const _liveThemePreviewLimit = 24;

/// A reusable widget for selecting terminal themes.
///
/// Displays themes in a grid with visual previews, organized by category
/// (dark/light) with search/filter capability.
class TerminalThemePicker extends ConsumerStatefulWidget {
  /// Creates a new [TerminalThemePicker].
  const TerminalThemePicker({
    required this.selectedThemeId,
    required this.onThemeSelected,
    super.key,
  });

  /// The currently selected theme ID.
  final String? selectedThemeId;

  /// Called when a theme is selected.
  final ValueChanged<TerminalThemeData> onThemeSelected;

  @override
  ConsumerState<TerminalThemePicker> createState() =>
      _TerminalThemePickerState();
}

class _TerminalThemePickerState extends ConsumerState<TerminalThemePicker> {
  String _searchQuery = '';
  String? _importingSchemeId;
  _ThemeFilter _filter = _ThemeFilter.all;
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themesAsync = ref.watch(allTerminalThemesProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final availableThemes = themesAsync.asData?.value ?? TerminalThemes.all;
    final liveSearchQuery = _searchQuery.trim();
    final liveResultsAsync = liveSearchQuery.length >= _liveThemeSearchMinLength
        ? ref.watch(itermColorSchemeSearchProvider(liveSearchQuery))
        : null;

    // Get the currently selected theme for the preview
    final currentTheme = widget.selectedThemeId != null
        ? _themeById(availableThemes, widget.selectedThemeId!)
        : null;

    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        // Currently selected preview (always visible)
        if (currentTheme != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _CurrentSelectionPreview(
                theme: currentTheme,
                onTap: () => widget.onThemeSelected(currentTheme),
              ),
            ),
          ),

        // Collapsible search and filter bar
        SliverAppBar(
          floating: true,
          snap: true,
          automaticallyImplyLeading: false,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          toolbarHeight: 120,
          flexibleSpace: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search field
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search themes...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
                const SizedBox(height: 12),
                // Filter chips
                Row(
                  children: [
                    _FilterChip(
                      label: 'All',
                      isSelected: _filter == _ThemeFilter.all,
                      onTap: () => setState(() => _filter = _ThemeFilter.all),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Dark',
                      isSelected: _filter == _ThemeFilter.dark,
                      onTap: () => setState(() => _filter = _ThemeFilter.dark),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Light',
                      isSelected: _filter == _ThemeFilter.light,
                      onTap: () => setState(() => _filter = _ThemeFilter.light),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
      body: themesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Could not load terminal themes.')),
        data: (themes) {
          final filtered = _filterThemes(themes);
          if (filtered.isEmpty && liveSearchQuery.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.palette_outlined,
                    size: 48,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No themes found',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            );
          }

          return _buildThemeGrid(
            filtered,
            installedThemes: themes,
            liveResultsAsync: liveResultsAsync,
          );
        },
      ),
    );
  }

  List<TerminalThemeData> _filterThemes(List<TerminalThemeData> themes) {
    var result = themes;

    // Apply type filter
    if (_filter == _ThemeFilter.dark) {
      result = result.where((t) => t.isDark).toList();
    } else if (_filter == _ThemeFilter.light) {
      result = result.where((t) => !t.isDark).toList();
    }

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      result = result
          .where((t) => t.name.toLowerCase().contains(query))
          .toList();
    }

    return result;
  }

  Widget _buildThemeGrid(
    List<TerminalThemeData> themes, {
    required List<TerminalThemeData> installedThemes,
    required AsyncValue<List<ItermColorSchemeMetadata>>? liveResultsAsync,
  }) {
    // Separate custom themes
    final builtInThemes = themes.where((t) => !t.isCustom).toList();
    final customThemes = themes.where((t) => t.isCustom).toList();

    // Group built-in by dark/light
    final darkThemes = builtInThemes.where((t) => t.isDark).toList();
    final lightThemes = builtInThemes.where((t) => !t.isDark).toList();

    final installedThemeIds = installedThemes.map((theme) => theme.id).toSet();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (customThemes.isNotEmpty) ...[
          const _SectionHeader(title: 'Custom Themes'),
          _ThemeGridSection(
            themes: customThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: widget.onThemeSelected,
            onLongPress: _handleCustomThemeLongPress,
          ),
          const SizedBox(height: 16),
        ],
        if (darkThemes.isNotEmpty && _filter != _ThemeFilter.light) ...[
          const _SectionHeader(title: 'Dark Themes'),
          _ThemeGridSection(
            themes: darkThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: widget.onThemeSelected,
          ),
          const SizedBox(height: 16),
        ],
        if (lightThemes.isNotEmpty && _filter != _ThemeFilter.dark) ...[
          const _SectionHeader(title: 'Light Themes'),
          _ThemeGridSection(
            themes: lightThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: widget.onThemeSelected,
          ),
        ],
        ..._buildLiveRepositorySection(
          installedThemeIds: installedThemeIds,
          liveResultsAsync: liveResultsAsync,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  List<Widget> _buildLiveRepositorySection({
    required Set<String> installedThemeIds,
    required AsyncValue<List<ItermColorSchemeMetadata>>? liveResultsAsync,
  }) {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return const [];
    }
    if (query.length < _liveThemeSearchMinLength) {
      return [
        const SizedBox(height: 8),
        const _SectionHeader(title: 'iTerm2ColorSchemes.com'),
        const _LiveThemeMessage(
          icon: Icons.search,
          message: 'Type at least 2 characters to search the live repository.',
        ),
      ];
    }

    return [
      const SizedBox(height: 8),
      const _SectionHeader(title: 'iTerm2ColorSchemes.com'),
      if (liveResultsAsync == null)
        const _LiveThemeMessage(
          icon: Icons.search,
          message: 'Type at least 2 characters to search the live repository.',
        )
      else
        liveResultsAsync.when(
          loading: () => const _LiveThemeMessage(
            icon: Icons.sync,
            message: 'Searching live repository...',
            isLoading: true,
          ),
          error: (_, _) => const _LiveThemeMessage(
            icon: Icons.cloud_off_outlined,
            message: 'Could not search iTerm2ColorSchemes.com.',
          ),
          data: (schemes) {
            final remoteSchemes = schemes
                .where((scheme) => !installedThemeIds.contains(scheme.id))
                .toList(growable: false);
            if (remoteSchemes.isEmpty) {
              return const _LiveThemeMessage(
                icon: Icons.check_circle_outline,
                message:
                    'No additional live themes found. Matching built-ins are shown above.',
              );
            }
            return _LiveThemePreviewGrid(
              schemes: remoteSchemes,
              importingSchemeId: _importingSchemeId,
              onSchemeSelected: _importLiveScheme,
            );
          },
        ),
    ];
  }

  Future<void> _importLiveScheme(ItermColorSchemeMetadata scheme) async {
    if (_importingSchemeId != null) {
      return;
    }

    setState(() => _importingSchemeId = scheme.id);
    try {
      final liveSchemeService = ref.read(itermColorSchemeServiceProvider);
      final importedTheme = await liveSchemeService.loadTheme(scheme);
      final builtInTheme = TerminalThemes.getById(importedTheme.id);
      final theme = builtInTheme ?? importedTheme.copyWith(isCustom: true);

      if (builtInTheme == null) {
        await ref.read(terminalThemeServiceProvider).saveCustomTheme(theme);
        ref
          ..invalidate(allTerminalThemesProvider)
          ..invalidate(customTerminalThemesProvider);
      }

      if (mounted) {
        widget.onThemeSelected(theme);
      }
    } on ItermColorSchemeException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not import ${scheme.name}: ${error.message}'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importingSchemeId = null);
      }
    }
  }

  void _handleCustomThemeLongPress(TerminalThemeData theme) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete theme',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(theme);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(TerminalThemeData theme) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete theme?'),
        content: Text('Are you sure you want to delete "${theme.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteCustomTheme(theme);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteCustomTheme(TerminalThemeData theme) async {
    try {
      await ref.read(terminalThemeServiceProvider).deleteCustomTheme(theme.id);
      ref
        ..invalidate(allTerminalThemesProvider)
        ..invalidate(customTerminalThemesProvider);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted "${theme.name}"')));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete "${theme.name}": $error')),
      );
    }
  }
}

TerminalThemeData? _themeById(Iterable<TerminalThemeData> themes, String id) {
  for (final theme in themes) {
    if (theme.id == id) {
      return theme;
    }
  }
  return TerminalThemes.getById(id);
}

class _LiveThemePreviewGrid extends StatelessWidget {
  const _LiveThemePreviewGrid({
    required this.schemes,
    required this.importingSchemeId,
    required this.onSchemeSelected,
  });

  final List<ItermColorSchemeMetadata> schemes;
  final String? importingSchemeId;
  final ValueChanged<ItermColorSchemeMetadata> onSchemeSelected;

  @override
  Widget build(BuildContext context) {
    final visibleSchemes = schemes
        .take(_liveThemePreviewLimit)
        .toList(growable: false);
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth < 360 ? 2 : (screenWidth < 600 ? 3 : 4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.9,
          ),
          itemCount: visibleSchemes.length,
          itemBuilder: (context, index) {
            final scheme = visibleSchemes[index];
            return _LiveThemePreviewCard(
              scheme: scheme,
              isImporting: importingSchemeId == scheme.id,
              isBusy: importingSchemeId != null,
              onTap: () => onSchemeSelected(scheme),
            );
          },
        ),
        if (schemes.length > visibleSchemes.length) ...[
          const SizedBox(height: 12),
          _LiveThemeMessage(
            icon: Icons.manage_search,
            message:
                'Showing the first ${visibleSchemes.length} live previews. '
                'Refine your search to narrow the results.',
          ),
        ],
      ],
    );
  }
}

class _LiveThemePreviewCard extends ConsumerWidget {
  const _LiveThemePreviewCard({
    required this.scheme,
    required this.isImporting,
    required this.isBusy,
    required this.onTap,
  });

  final ItermColorSchemeMetadata scheme;
  final bool isImporting;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeAsync = ref.watch(itermColorSchemeThemeProvider(scheme));
    return themeAsync.when(
      data: (theme) => _LiveThemePreviewFrame(
        isImporting: isImporting,
        child: ThemePreviewCard(
          theme: theme,
          isSelected: false,
          trailingIcon: Icons.download_outlined,
          onTap: isBusy ? () {} : onTap,
        ),
      ),
      loading: () => _LiveThemePreviewPlaceholder(
        name: scheme.name,
        isImporting: isImporting,
        isBusy: isBusy,
        onTap: onTap,
      ),
      error: (_, _) => _LiveThemePreviewError(
        name: scheme.name,
        isBusy: isBusy,
        onTap: onTap,
      ),
    );
  }
}

class _LiveThemePreviewFrame extends StatelessWidget {
  const _LiveThemePreviewFrame({
    required this.child,
    required this.isImporting,
  });

  final Widget child;
  final bool isImporting;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      if (isImporting)
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.scrim.withAlpha(90),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(child: CircularProgressIndicator()),
        ),
    ],
  );
}

class _LiveThemePreviewPlaceholder extends StatelessWidget {
  const _LiveThemePreviewPlaceholder({
    required this.name,
    required this.isImporting,
    required this.isBusy,
    required this.onTap,
  });

  final String name;
  final bool isImporting;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _LiveThemePreviewFrame(
    isImporting: isImporting,
    child: _LiveThemePreviewShell(
      name: name,
      icon: Icons.download_outlined,
      onTap: isBusy ? null : onTap,
      child: const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    ),
  );
}

class _LiveThemePreviewError extends StatelessWidget {
  const _LiveThemePreviewError({
    required this.name,
    required this.isBusy,
    required this.onTap,
  });

  final String name;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _LiveThemePreviewShell(
      name: name,
      icon: Icons.refresh,
      onTap: isBusy ? null : onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, color: colorScheme.error),
          const SizedBox(height: 8),
          Text(
            'Preview unavailable',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveThemePreviewShell extends StatelessWidget {
  const _LiveThemePreviewShell({
    required this.name,
    required this.icon,
    required this.child,
    required this.onTap,
  });

  final String name;
  final IconData icon;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: colorScheme.surfaceContainerHighest,
                  child: child,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  border: Border(top: BorderSide(color: colorScheme.outline)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveThemeMessage extends StatelessWidget {
  const _LiveThemeMessage({
    required this.icon,
    required this.message,
    this.isLoading = false,
  });

  final IconData icon;
  final String message;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (isLoading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ThemeFilter { all, dark, light }

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primary : colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outline,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isSelected ? colorScheme.onPrimary : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CurrentSelectionPreview extends StatelessWidget {
  const _CurrentSelectionPreview({required this.theme, required this.onTap});

  final TerminalThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withAlpha(50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withAlpha(100)),
      ),
      child: Row(
        children: [
          // Mini preview
          Container(
            width: 60,
            height: 44,
            decoration: BoxDecoration(
              color: theme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outline),
            ),
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    _colorDot(theme.green),
                    _colorDot(theme.blue),
                    _colorDot(theme.red),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  r'$ _',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 8,
                    color: theme.foreground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Currently Selected',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  theme.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          // Check icon
          Icon(Icons.check_circle, color: colorScheme.primary, size: 24),
        ],
      ),
    );
  }

  Widget _colorDot(Color color) => Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.only(right: 2),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _ThemeGridSection extends StatelessWidget {
  const _ThemeGridSection({
    required this.themes,
    required this.selectedThemeId,
    required this.onThemeSelected,
    this.onLongPress,
  });

  final List<TerminalThemeData> themes;
  final String? selectedThemeId;
  final ValueChanged<TerminalThemeData> onThemeSelected;
  final ValueChanged<TerminalThemeData>? onLongPress;

  @override
  Widget build(BuildContext context) {
    // Use responsive grid based on screen width
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth < 360 ? 2 : (screenWidth < 600 ? 3 : 4);
    final resolvedSelectedThemeId = selectedThemeId == null
        ? null
        : TerminalThemes.resolveThemeId(selectedThemeId!);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.9,
      ),
      itemCount: themes.length,
      itemBuilder: (context, index) {
        final theme = themes[index];
        return ThemePreviewCard(
          theme: theme,
          isSelected: theme.id == resolvedSelectedThemeId,
          onTap: () => onThemeSelected(theme),
          onLongPress: onLongPress != null ? () => onLongPress!(theme) : null,
        );
      },
    );
  }
}

/// Shows a theme picker dialog and returns the selected theme.
Future<TerminalThemeData?> showThemePickerDialog({
  required BuildContext context,
  required String? currentThemeId,
}) async => showModalBottomSheet<TerminalThemeData>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => DraggableScrollableSheet(
    initialChildSize: 0.85,
    minChildSize: 0.5,
    maxChildSize: 0.95,
    expand: false,
    builder: (context, scrollController) => Column(
      children: [
        // Handle bar
        Container(
          margin: const EdgeInsets.only(top: 12),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Title
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                'Select Theme',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        // Picker
        Expanded(
          child: TerminalThemePicker(
            selectedThemeId: currentThemeId,
            onThemeSelected: (theme) => Navigator.pop(context, theme),
          ),
        ),
      ],
    ),
  ),
);
