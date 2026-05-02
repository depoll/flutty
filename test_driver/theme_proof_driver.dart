import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outputPath =
      Platform.environment['MONKEYSSH_THEME_PROOF_DIR'] ??
      '/tmp/monkeyssh-theme-proof';
  final outputDir = Directory(outputPath);
  await outputDir.create(recursive: true);

  await integrationDriver(
    onScreenshot:
        (
          String screenshotName,
          List<int> screenshotBytes, [
          Map<String, Object?>? args,
        ]) async {
          final file = File('${outputDir.path}/$screenshotName.png');
          await file.writeAsBytes(screenshotBytes, flush: true);
          return true;
        },
  );
}
