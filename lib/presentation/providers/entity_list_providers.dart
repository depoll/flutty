import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';

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
