import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Authentication state.
enum AuthState {
  /// Not yet checked.
  unknown,

  /// No authentication configured.
  notConfigured,

  /// Authentication configured but not unlocked.
  locked,

  /// Successfully authenticated.
  unlocked,
}

/// Authentication method.
enum AuthMethod {
  /// No authentication.
  none,

  /// PIN code.
  pin,

  /// Biometric authentication.
  biometric,

  /// Both PIN and biometric available.
  both,
}

/// Service for handling app authentication (PIN/biometric).
class AuthService {
  /// Creates a new [AuthService].
  AuthService({FlutterSecureStorage? storage, LocalAuthentication? localAuth})
    : _storage = storage ?? const FlutterSecureStorage(),
      _localAuth = localAuth ?? LocalAuthentication();

  final FlutterSecureStorage _storage;
  final LocalAuthentication _localAuth;

  static const _pinKey = 'flutty_pin_hash';
  static const _pinSaltKey = 'flutty_pin_salt';
  static const _pinMetadataKey = 'flutty_pin_kdf_metadata';
  static const _authEnabledKey = 'flutty_auth_enabled';
  static const _biometricEnabledKey = 'flutty_biometric_enabled';
  static const _pinKdfVersion = 1;
  static const _pinKdfIterations = 120000;
  static const _pinKdfBits = 256;
  static const _pinSaltLength = 16;
  Future<void> _pinWriteQueue = Future<void>.value();

  /// Check if authentication is enabled.
  Future<bool> isAuthEnabled() async {
    final value = await _storage.read(key: _authEnabledKey);
    return value == 'true';
  }

  /// Check if biometric is enabled.
  Future<bool> isBiometricEnabled() async {
    final value = await _storage.read(key: _biometricEnabledKey);
    return value == 'true';
  }

  /// Check if device supports biometric authentication.
  Future<bool> isBiometricAvailable() async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics;
      if (!isAvailable) return false;

      final biometrics = await _localAuth.getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// Get available biometric types.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  /// Get the current auth method.
  Future<AuthMethod> getAuthMethod() async {
    final authEnabled = await isAuthEnabled();
    if (!authEnabled) return AuthMethod.none;

    final biometricEnabled = await isBiometricEnabled();
    final biometricAvailable = await isBiometricAvailable();

    if (biometricEnabled && biometricAvailable) {
      final hasPin = await _storage.read(key: _pinKey) != null;
      return hasPin ? AuthMethod.both : AuthMethod.biometric;
    }

    return AuthMethod.pin;
  }

  /// Set up PIN authentication.
  Future<void> setupPin(String pin) async {
    await _storePin(pin, enableAuth: true);
  }

  /// Enable or disable biometric authentication.
  Future<void> setBiometricEnabled({required bool enabled}) async {
    await _storage.write(key: _biometricEnabledKey, value: enabled.toString());
  }

  /// Verify PIN.
  Future<bool> verifyPin(String pin) async {
    final storedPinData = await _storage.read(key: _pinKey);
    if (storedPinData == null) return false;

    final pinRecord = _parsePinRecord(storedPinData);
    if (pinRecord == null) {
      return false;
    }
    if (pinRecord.version != _pinKdfVersion) {
      return false;
    }
    if (pinRecord.iterations <= 0 || pinRecord.iterations > 1000000) {
      return false;
    }

    final salt = await _readSalt();
    if (salt == null) return false;

    final inputHash = await _derivePinHash(
      pin: pin,
      salt: salt,
      iterations: pinRecord.iterations,
    );
    return _constantTimeEquals(pinRecord.hash, inputHash);
  }

  /// Authenticate with biometrics.
  Future<bool> authenticateWithBiometrics({
    String reason = 'Authenticate to access MonkeySSH',
  }) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on PlatformException {
      return false;
    }
  }

  /// Authenticate with any available method.
  Future<bool> authenticate({
    String? pin,
    String reason = 'Authenticate to access MonkeySSH',
  }) async {
    final method = await getAuthMethod();

    switch (method) {
      case AuthMethod.none:
        return true;

      case AuthMethod.pin:
        if (pin == null) return false;
        return verifyPin(pin);

      case AuthMethod.biometric:
        return authenticateWithBiometrics(reason: reason);

      case AuthMethod.both:
        // Try biometric first, fall back to PIN
        final biometricSuccess = await authenticateWithBiometrics(
          reason: reason,
        );
        if (biometricSuccess) return true;
        if (pin != null) return verifyPin(pin);
        return false;
    }
  }

  /// Disable authentication.
  Future<void> disableAuth() async {
    await _storage.delete(key: _pinKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinMetadataKey);
    await _storage.delete(key: _authEnabledKey);
    await _storage.delete(key: _biometricEnabledKey);
  }

  /// Change PIN.
  Future<bool> changePin(String currentPin, String newPin) async {
    final isValid = await verifyPin(currentPin);
    if (!isValid) return false;

    await setupPin(newPin);
    return true;
  }

  Future<void> _storePin(String pin, {required bool enableAuth}) async {
    await _withPinWriteLock(() async {
      final salt = await _getOrCreateSalt();
      final hash = await _derivePinHash(
        pin: pin,
        salt: salt,
        iterations: _pinKdfIterations,
      );
      await _storage.write(
        key: _pinKey,
        value: jsonEncode({
          'version': _pinKdfVersion,
          'iterations': _pinKdfIterations,
          'hash': hash,
        }),
      );
      await _storage.write(
        key: _pinMetadataKey,
        value: jsonEncode({
          'version': _pinKdfVersion,
          'iterations': _pinKdfIterations,
        }),
      );
      if (enableAuth) {
        await _storage.write(key: _authEnabledKey, value: 'true');
      }
    });
  }

  Future<List<int>> _getOrCreateSalt() async {
    final existingSalt = await _readSalt();
    if (existingSalt != null) return existingSalt;

    final salt = SecretKeyData.random(length: _pinSaltLength).bytes;
    await _storage.write(key: _pinSaltKey, value: base64Encode(salt));
    return salt;
  }

  Future<List<int>?> _readSalt() async {
    final saltData = await _storage.read(key: _pinSaltKey);
    if (saltData == null) return null;

    try {
      return base64Decode(saltData);
    } on FormatException {
      return null;
    }
  }

  Future<String> _derivePinHash({
    required String pin,
    required List<int> salt,
    required int iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: _pinKdfBits,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    final hashBytes = await secretKey.extractBytes();
    return base64Encode(hashBytes);
  }

  _PinHashRecord? _parsePinRecord(String value) {
    dynamic decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }

    if (decoded is! Map<String, dynamic>) return null;

    final version = decoded['version'];
    final iterations = decoded['iterations'];
    final hash = decoded['hash'];

    if (version is! int || iterations is! int || hash is! String) {
      return null;
    }

    return _PinHashRecord(version: version, iterations: iterations, hash: hash);
  }

  bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    var mismatch = aBytes.length ^ bBytes.length;
    final maxLength = aBytes.length > bBytes.length
        ? aBytes.length
        : bBytes.length;
    for (var i = 0; i < maxLength; i++) {
      final aValue = i < aBytes.length ? aBytes[i] : 0;
      final bValue = i < bBytes.length ? bBytes[i] : 0;
      mismatch |= aValue ^ bValue;
    }
    return mismatch == 0;
  }

  Future<void> _withPinWriteLock(Future<void> Function() action) async {
    final operation = _pinWriteQueue.then<void>((_) => action());
    _pinWriteQueue = operation.catchError((_) {});
    await operation;
  }
}

class _PinHashRecord {
  _PinHashRecord({
    required this.version,
    required this.iterations,
    required this.hash,
  });

  final int version;
  final int iterations;
  final String hash;
}

/// Provider for [AuthService].
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Provider for the current authentication state.
final authStateProvider = NotifierProvider<AuthStateNotifier, AuthState>(
  AuthStateNotifier.new,
);

/// Notifier for authentication state.
class AuthStateNotifier extends Notifier<AuthState> {
  late final AuthService _authService;
  bool _disposed = false;

  @override
  AuthState build() {
    _authService = ref.watch(authServiceProvider);
    ref.onDispose(() => _disposed = true);
    Future.microtask(_init);
    return AuthState.unknown;
  }

  Future<void> _init() async {
    final isEnabled = await _authService.isAuthEnabled();
    if (_disposed) return;
    state = isEnabled ? AuthState.locked : AuthState.notConfigured;
  }

  /// Attempt to unlock with PIN.
  Future<bool> unlockWithPin(String pin) async {
    final success = await _authService.verifyPin(pin);
    if (success) {
      state = AuthState.unlocked;
    }
    return success;
  }

  /// Attempt to unlock with biometrics.
  Future<bool> unlockWithBiometrics() async {
    final success = await _authService.authenticateWithBiometrics();
    if (success) {
      state = AuthState.unlocked;
    }
    return success;
  }

  /// Lock the app.
  void lock() {
    state = AuthState.locked;
  }

  /// Skip authentication (when not configured).
  void skip() {
    state = AuthState.unlocked;
  }

  /// Reset state after configuring auth.
  Future<void> refresh() async {
    await _init();
  }
}
