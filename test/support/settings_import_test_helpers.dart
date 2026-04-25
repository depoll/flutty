// ignore_for_file: public_member_api_docs, use_super_parameters

import 'dart:io' show Directory, File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';

const _filePickerChannel = MethodChannel(
  'miguelruivo.flutter.plugins.filepicker',
);

void setFakeFilePickerResult({required FilePickerResult? result}) {
  Future<List<String>?>? nativeFilePaths;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_filePickerChannel, (call) async {
        if (call.method case 'pickFiles') {
          return nativeFilePaths ??= _materializeNativeFilePaths(result);
        }
        if (call.method
            case 'any' ||
                'custom' ||
                'image' ||
                'video' ||
                'media' ||
                'audio') {
          return result?.files.map(_serializePlatformFile).toList();
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, null),
  );
}

Future<List<String>?> _materializeNativeFilePaths(
  FilePickerResult? result,
) async {
  if (result == null) {
    return null;
  }

  final tempDirectory = await Directory.systemTemp.createTemp(
    'flutty-file-picker-',
  );
  addTearDown(() => tempDirectory.delete(recursive: true));

  final filePaths = <String>[];
  for (final file in result.files) {
    final tempFile = File('${tempDirectory.path}/${file.name}');
    await tempFile.writeAsBytes(file.bytes ?? const <int>[]);
    filePaths.add(tempFile.path);
  }
  return filePaths;
}

Map<String, Object?> _serializePlatformFile(PlatformFile file) => {
  'path': file.path,
  'name': file.name,
  'bytes': file.bytes,
  'size': file.size,
  'identifier': file.identifier,
};

class EntityProviderProbe extends ConsumerWidget {
  const EntityProviderProbe({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref
      ..watch(allHostsProvider)
      ..watch(allKeysProvider)
      ..watch(allGroupsProvider);
    return const SizedBox.shrink();
  }
}

class MockAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;
}

class FakeAuthService extends AuthService {
  @override
  Future<bool> isAuthEnabled() async => false;

  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<bool> isDeviceAuthSupported() async => false;

  @override
  Future<bool> isBiometricHardwareSupported() async => false;

  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [];

  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: false,
        isBiometricHardwareSupported: false,
        enrolledBiometrics: [],
      );
}

class FakeSecureTransferService extends SecureTransferService {
  FakeSecureTransferService(
    AppDatabase db,
    KeyRepository keyRepository,
    HostRepository hostRepository, {
    required this.payload,
  }) : super(db, keyRepository, hostRepository);

  final TransferPayload payload;
  int importCallCount = 0;

  @override
  Future<TransferPayload> decryptPayload({
    required String encodedPayload,
    required String transferPassphrase,
  }) async => payload;

  @override
  MigrationPreview previewMigrationPayload(TransferPayload payload) =>
      MigrationPreview(
        settingsCount: 0,
        hostCount: (payload.data['hosts'] as List).length,
        keyCount: (payload.data['keys'] as List).length,
        groupCount: (payload.data['groups'] as List).length,
        snippetCount: (payload.data['snippets'] as List).length,
        snippetFolderCount: (payload.data['snippetFolders'] as List).length,
        portForwardCount: (payload.data['portForwards'] as List).length,
        knownHostCount: (payload.data['knownHosts'] as List).length,
      );

  @override
  Future<void> importFullMigrationPayload({
    required TransferPayload payload,
    required MigrationImportMode mode,
  }) async {
    importCallCount += 1;
  }
}

class StaticThemeModeNotifier extends ThemeModeNotifier {
  @override
  ThemeMode build() => ThemeMode.system;
}

class StaticFontSizeNotifier extends FontSizeNotifier {
  @override
  double build() => 14;
}

class StaticFontFamilyNotifier extends FontFamilyNotifier {
  @override
  String build() => 'System Monospace';
}

class StaticCursorStyleNotifier extends CursorStyleNotifier {
  @override
  String build() => 'block';
}

class StaticBellSoundNotifier extends BellSoundNotifier {
  @override
  bool build() => true;
}

class StaticTerminalThemeSettingsNotifier
    extends TerminalThemeSettingsNotifier {
  @override
  TerminalThemeSettings build() => const TerminalThemeSettings(
    lightThemeId: 'github-light',
    darkThemeId: 'dracula',
  );
}
