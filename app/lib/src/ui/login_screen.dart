import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';

// Debug builds can sign in by themselves for Simulator testing:
//   flutter run --dart-define=SB_DEV_PASSWORD=...
const _devServer = String.fromEnvironment('SB_DEV_SERVER');
const _devUser = String.fromEnvironment('SB_DEV_USER');
const _devPassword = String.fromEnvironment('SB_DEV_PASSWORD');

// The server the sign-in screen fills in, set at build time; the scripts in
// tool/ pass it from SB_DEFAULT_SERVER or tool/local.env. Empty by default.
const defaultServer = String.fromEnvironment('SB_DEFAULT_SERVER');

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController(text: _devServer.isEmpty ? defaultServer : _devServer);
  final _user = TextEditingController(text: _devUser);
  final _password = TextEditingController(text: kDebugMode ? _devPassword : '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (kDebugMode && _devPassword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).login(
            server: _server.text,
            username: _user.text,
            password: _password.text,
          );
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(Object e) {
    final s = e.toString();
    if (s.contains('M_FORBIDDEN')) return 'Wrong username or password.';
    if (s.contains("can't reach") || s.contains('dns') || s.contains('connect')) {
      return "Can't reach the server. Check that Tailscale is on.";
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.forum_rounded, size: 56, color: scheme.primary),
                    const SizedBox(height: 16),
                    Text(
                      'Switchboard',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sign in to your server',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _server,
                      decoration: const InputDecoration(labelText: 'Server', hintText: 'switchboard.<tailnet>.ts.net'),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: 'Username'),
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _busy ? null : _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
