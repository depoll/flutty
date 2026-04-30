import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderBase;

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/terminal_theme_service.dart';

/// Shared stream of all saved hosts for presentation screens.
final allHostsProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});

/// Shared stream of all saved SSH keys for presentation screens.
final allKeysProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});

/// Shared stream of all host groups for presentation screens.
final allGroupsProvider = StreamProvider<List<Group>>((ref) {
  final repo = ref.watch(groupRepositoryProvider);
  return repo.watchAll();
});

/// Signature for invalidating shared providers from any Riverpod context.
typedef ProviderInvalidator =
    void Function(ProviderBase<Object?> provider, {bool asReload});

/// Refreshes shared entity list providers after migration imports replace data.
void invalidateImportedEntityProviders(ProviderInvalidator invalidate) {
  invalidate(allHostsProvider);
  invalidate(allKeysProvider);
  invalidate(allGroupsProvider);
}

/// Refreshes presentation providers that depend on synced settings and data.
void invalidateSyncedDataProviders(ProviderInvalidator invalidate) {
  invalidate(themeModeNotifierProvider);
  invalidate(fontSizeNotifierProvider);
  invalidate(fontFamilyNotifierProvider);
  invalidate(cursorStyleNotifierProvider);
  invalidate(bellSoundNotifierProvider);
  invalidate(terminalThemeSettingsProvider);
  invalidate(allTerminalThemesProvider);
  invalidate(customTerminalThemesProvider);
  invalidateImportedEntityProviders(invalidate);
}
