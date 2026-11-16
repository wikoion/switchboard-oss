import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../rust/api/client.dart';
import '../rust/api/types.dart';
import 'push.dart';

const _sessionKey = 'session';
const _passphraseKey = 'store_passphrase';

/// The signed-in core, or null when signed out.
final sessionProvider =
    AsyncNotifierProvider<SessionController, SwitchboardCore?>(SessionController.new);

/// The core, for widgets that only exist while signed in.
final coreProvider = Provider<SwitchboardCore>((ref) {
  final core = ref.watch(sessionProvider).value;
  if (core == null) throw StateError('not signed in');
  return core;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  return ref.watch(coreProvider).subscribeSyncStatus();
});

class SessionController extends AsyncNotifier<SwitchboardCore?> {
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<SwitchboardCore?> build() async {
    final saved = await _storage.read(key: _sessionKey);
    if (saved == null) return null;
    try {
      final core = await SwitchboardCore.restore(
        sessionJson: saved,
        dataDir: await _dataDir(),
        passphrase: await _passphrase(),
      );
      await core.startSync();
      await shareSessionWithExtension(core);
      return core;
    } catch (_) {
      // A session that no longer restores (store wiped, token revoked)
      // sends the user back to sign-in rather than a dead app.
      await _storage.delete(key: _sessionKey);
      return null;
    }
  }

  Future<void> login({
    required String server,
    required String username,
    required String password,
  }) async {
    final core = await SwitchboardCore.login(
      server: server,
      username: username,
      password: password,
      deviceName: Platform.isLinux ? 'Switchboard Linux' : 'Switchboard iOS',
      dataDir: await _dataDir(),
      passphrase: await _passphrase(),
    );
    await _storage.write(key: _sessionKey, value: core.sessionJson());
    await core.startSync();
    await shareSessionWithExtension(core);
    state = AsyncData(core);
  }

  Future<void> logout() async {
    final core = state.value;
    await _storage.delete(key: _sessionKey);
    state = const AsyncData(null);
    await shareSessionWithExtension(null);
    try {
      await core?.logout();
    } catch (_) {
      // Signed out locally either way.
    }
  }

  Future<String> _dataDir() async => (await getApplicationSupportDirectory()).path;

  /// The local store's key: 32 random bytes kept in the Keychain on iOS and
  /// libsecret on Linux.
  Future<String> _passphrase() async {
    final existing = await _storage.read(key: _passphraseKey);
    if (existing != null) return existing;
    final rng = Random.secure();
    final key = base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
    await _storage.write(key: _passphraseKey, value: key);
    return key;
  }
}
