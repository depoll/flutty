import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/app.dart';
import 'app/host_key_prompt.dart';
import 'domain/services/host_key_prompt_handler_provider.dart';

/// Entry point for the MonkeySSH client.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(
    ProviderScope(
      overrides: [
        hostKeyPromptHandlerProvider.overrideWith(
          (ref) => createHostKeyPromptHandler(),
        ),
      ],
      child: const FluttyApp(),
    ),
  );
}
