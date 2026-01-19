import 'dart:convert';

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
  static const _authEnabledKey = 'flutty_auth_enabled';
  static const _biometricEnabledKey = 'flutty_biometric_enabled';

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
    final hash = _hashPin(pin);
    await _storage.write(key: _pinKey, value: hash);
    await _storage.write(key: _authEnabledKey, value: 'true');
  }

  /// Enable or disable biometric authentication.
  Future<void> setBiometricEnabled({required bool enabled}) async {
    await _storage.write(key: _biometricEnabledKey, value: enabled.toString());
  }

  /// Verify PIN.
  Future<bool> verifyPin(String pin) async {
    final storedHash = await _storage.read(key: _pinKey);
    if (storedHash == null) return false;

    final inputHash = _hashPin(pin);
    return storedHash == inputHash;
  }

  /// Authenticate with biometrics.
  Future<bool> authenticateWithBiometrics({
    String reason = 'Authenticate to access Flutty',
  }) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }

  /// Authenticate with any available method.
  Future<bool> authenticate({
    String? pin,
    String reason = 'Authenticate to access Flutty',
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

  String _hashPin(String pin) {
    // Simple hash for PIN - in production, use a proper KDF
    final bytes = utf8.encode('${pin}flutty_salt');
    var hash = 0;
    for (final byte in bytes) {
      hash = ((hash << 5) - hash) + byte;
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }
}

/// Provider for [AuthService].
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Provider for the current authentication state.
final authStateProvider = StateNotifierProvider<AuthStateNotifier, AuthState>(
  (ref) => AuthStateNotifier(ref.watch(authServiceProvider)),
);

/// Notifier for authentication state.
class AuthStateNotifier extends StateNotifier<AuthState> {
  /// Creates a new [AuthStateNotifier].
  AuthStateNotifier(this._authService) : super(AuthState.unknown) {
    Future.microtask(_init);
  }

  final AuthService _authService;

  Future<void> _init() async {
    final isEnabled = await _authService.isAuthEnabled();
    if (!mounted) return;
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
