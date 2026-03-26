import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host_key_verification.dart';

/// Provider for the optional UI-backed host-key prompt handler.
final hostKeyPromptHandlerProvider = Provider<HostKeyPromptHandler?>(
  (_) => null,
);
