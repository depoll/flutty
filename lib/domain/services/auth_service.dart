import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _defaultAuthAppName = 'MonkeySSH';

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

/// Current platform biometric readiness.
@immutable
class BiometricAvailability {
  /// Creates a new [BiometricAvailability].
  const BiometricAvailability({
    required this.isDeviceAuthSupported,
    required this.isBiometricHardwareSupported,
    required this.enrolledBiometrics,
  });

  /// Whether the device supports local authentication at all.
  ///
  /// This can be true for device PIN/pattern/passcode even when no biometric
  /// hardware is present.
  final bool isDeviceAuthSupported;

  /// Whether biometric hardware is supported on this device.
  final bool isBiometricHardwareSupported;

  /// Biometrics enrolled and currently available to local_auth.
  final List<BiometricType> enrolledBiometrics;

  /// Whether biometric authentication can be used without setup elsewhere.
  bool get canAuthenticateWithBiometrics =>
      isBiometricHardwareSupported && enrolledBiometrics.isNotEmpty;

  /// Whether biometric hardware exists but the user must enroll first.
  bool get needsBiometricEnrollment =>
      isBiometricHardwareSupported && enrolledBiometrics.isEmpty;

  /// Whether only non-biometric device credentials are supported.
  bool get supportsDeviceCredentialOnly =>
      isDeviceAuthSupported && !isBiometricHardwareSupported;
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
  static const _pinHashLength = _pinKdfBits ~/ 8;
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

  /// Check if device has biometric hardware.
  Future<bool> isBiometricSupported() async => _isBiometricHardwareSupported();

  /// Check if device supports local authentication.
  Future<bool> isDeviceAuthSupported() async {
    try {
      return await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  /// Check if biometrics are enrolled and ready to use.
  Future<bool> isBiometricAvailable() async {
    if (!await _isBiometricHardwareSupported()) return false;

    final biometrics = await getAvailableBiometrics();
    return biometrics.isNotEmpty;
  }

  /// Get the current platform biometric readiness.
  Future<BiometricAvailability> getBiometricAvailability() async {
    final deviceAuthSupported = await isDeviceAuthSupported();
    final biometricHardwareSupported = await _isBiometricHardwareSupported();
    final enrolledBiometrics = biometricHardwareSupported
        ? await getAvailableBiometrics()
        : const <BiometricType>[];

    return BiometricAvailability(
      isDeviceAuthSupported: deviceAuthSupported,
      isBiometricHardwareSupported: biometricHardwareSupported,
      enrolledBiometrics: enrolledBiometrics,
    );
  }

  Future<bool> _isBiometricHardwareSupported() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  /// Get available biometric types.
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    } on LocalAuthException {
      return [];
    }
  }

  /// Get the current auth method.
  Future<AuthMethod> getAuthMethod() async {
    final authEnabled = await isAuthEnabled();
    if (!authEnabled) return AuthMethod.none;

    final hasUsablePin = await _hasUsablePin();
    final biometricEnabled = await isBiometricEnabled();
    final biometricAvailable = biometricEnabled && await isBiometricAvailable();

    if (biometricEnabled && biometricAvailable) {
      return hasUsablePin ? AuthMethod.both : AuthMethod.biometric;
    }

    if (hasUsablePin) {
      return AuthMethod.pin;
    }

    throw StateError(
      'Authentication is enabled but no usable authentication method is available.',
    );
  }

  /// Set up PIN authentication.
  Future<void> setupPin(String pin) async {
    await _storePin(pin, enableAuth: true);
  }

  /// Enable or disable biometric authentication.
  Future<void> setBiometricEnabled({required bool enabled}) async {
    final canEnable = !enabled || await isBiometricAvailable();
    await _storage.write(
      key: _biometricEnabledKey,
      value: (enabled && canEnable).toString(),
    );
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
    if (!_hasValidStoredPinHash(pinRecord.hash)) {
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
  Future<bool> authenticateWithBiometrics({String? reason}) async {
    if (!await isBiometricAvailable()) {
      return false;
    }

    try {
      final localizedReason = reason ?? await _defaultLocalizedReason();
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  /// Authenticate with any available method.
  Future<bool> authenticate({String? pin, String? reason}) async {
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
      final salt = base64Decode(saltData);
      if (salt.length != _pinSaltLength) {
        return null;
      }
      return salt;
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

  bool _hasValidStoredPinHash(String hash) {
    if (hash.isEmpty) return false;

    try {
      final decodedHash = base64Decode(hash);
      return decodedHash.length == _pinHashLength;
    } on FormatException {
      return false;
    }
  }

  Future<bool> _hasUsablePin() async {
    final storedPinData = await _storage.read(key: _pinKey);
    if (storedPinData == null) return false;

    final pinRecord = _parsePinRecord(storedPinData);
    if (pinRecord == null || !_hasValidStoredPinHash(pinRecord.hash)) {
      return false;
    }
    if (pinRecord.version != _pinKdfVersion) {
      return false;
    }
    if (pinRecord.iterations <= 0 || pinRecord.iterations > 1000000) {
      return false;
    }

    final salt = await _readSalt();
    return salt != null;
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

Future<String> _defaultLocalizedReason() async {
  final packageInfo = await PackageInfo.fromPlatform();
  final appName = packageInfo.appName.trim();
  final normalizedAppName = appName.isEmpty ? _defaultAuthAppName : appName;
  return 'Authenticate to access $normalizedAppName';
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
    final isEnabled = await _loadAuthEnabledState();
    if (_disposed) return;
    state = isEnabled ? AuthState.locked : AuthState.notConfigured;
  }

  Future<bool> _loadAuthEnabledState() async {
    try {
      return await _authService.isAuthEnabled();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'auth',
          context: ErrorDescription(
            'while determining whether app authentication is enabled',
          ),
        ),
      );
      return true;
    }
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
  Future<void> lock() async {
    final isEnabled = await _loadAuthEnabledState();
    if (_disposed) return;
    state = isEnabled ? AuthState.locked : AuthState.notConfigured;
  }

  /// Lock the app immediately when auth is already known to be configured.
  void lockForAutoLock() {
    if (_disposed) return;
    state = AuthState.locked;
  }

  /// Skip authentication setup (when not configured).
  void skip() {
    state = AuthState.notConfigured;
  }

  /// Reset state after configuring auth.
  Future<void> refresh() async {
    await _init();
  }
}
