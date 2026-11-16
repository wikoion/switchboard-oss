// One generic renderer for every bridgev2 network: it walks the login
// steps the bridge returns and draws each step type natively.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/hub.dart';
import 'web_login.dart';

class LinkScreen extends ConsumerStatefulWidget {
  const LinkScreen({super.key, required this.bridgeId, this.flowId, this.loginId});

  final String bridgeId;
  final String? flowId;

  /// Set when relinking an existing account.
  final String? loginId;

  @override
  ConsumerState<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends ConsumerState<LinkScreen> {
  Bridge? _bridge;
  LoginFlow? _flow;
  LoginStep? _step;
  String? _error;
  bool _busy = false;

  /// Bumped whenever the login restarts or the screen closes, so answers
  /// from an abandoned long poll are ignored.
  int _generation = 0;

  // Kept from the start: dispose() cancels the login, and ref can't be
  // used there.
  late final HubApi _hub;

  @override
  void initState() {
    super.initState();
    _hub = ref.read(hubProvider);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _cancelQuietly();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bridges = await ref.read(bridgesProvider.future);
      final bridge = bridges.firstWhere((b) => b.id == widget.bridgeId);
      setState(() => _bridge = bridge);
      final flows = bridge.flows;
      final wanted = widget.flowId == null ? null : flows.where((f) => f.id == widget.flowId).firstOrNull;
      if (wanted != null) {
        await _start(wanted);
      } else if (flows.length == 1) {
        await _start(flows.single);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _start(LoginFlow flow) async {
    _cancelQuietly();
    final gen = ++_generation;
    setState(() {
      _flow = flow;
      _step = null;
      _error = null;
      _busy = true;
    });
    try {
      final step = await _hub.start(widget.bridgeId, flow.id, loginId: widget.loginId);
      if (gen == _generation) _show(step, gen);
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = '$e');
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  void _show(LoginStep step, int gen) {
    if (!mounted) return;
    setState(() => _step = step);
    if (step.type == 'display_and_wait') unawaited(_wait(step, gen));
    if (step.type == 'complete') ref.invalidate(bridgesProvider);
  }

  Future<void> _wait(LoginStep step, int gen) async {
    try {
      final next = await _hub.wait(widget.bridgeId, step);
      if (gen == _generation) _show(next, gen);
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _submit(Map<String, String> values) => _send(values, _hub.submitInput);

  Future<void> _submitCookies(Map<String, String> values) => _send(values, _hub.submitCookies);

  Future<void> _send(
    Map<String, String> values,
    Future<LoginStep> Function(String bridge, LoginStep step, Map<String, String> values) send,
  ) async {
    final step = _step!;
    final gen = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await send(widget.bridgeId, step, values);
      if (gen == _generation) _show(next, gen);
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = '$e');
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  void _cancelQuietly() {
    final step = _step;
    if (step == null || step.type == 'complete' || step.loginId.isEmpty) return;
    unawaited(_hub.cancel(widget.bridgeId, step.loginId).catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final bridge = _bridge;
    return Scaffold(
      appBar: AppBar(title: Text(bridge == null ? 'Add account' : 'Link ${bridge.network}')),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(key: ValueKey('${_step?.stepId}${_step?.displayData}$_error'), child: _content()),
        ),
      ),
    );
  }

  Widget _content() {
    final bridge = _bridge;
    if (_error != null) return _ErrorView(message: _error!, onRetry: _flow == null ? _load : () => _start(_flow!));
    if (bridge == null || (_busy && _step == null)) return const Center(child: CircularProgressIndicator());
    final step = _step;
    if (step == null) return _FlowPicker(bridge: bridge, onPick: _start);
    return switch (step.type) {
      'display_and_wait' => _DisplayStep(
          step: step,
          bridge: bridge,
          alternative: _alternativeFor(bridge),
          onAlternative: (f) => _start(f),
        ),
      'user_input' => _InputStep(step: step, busy: _busy, onSubmit: _submit),
      'cookies' when step.cookies != null => WebLoginStep(
          key: ObjectKey(step),
          step: step,
          network: bridge.network,
          busy: _busy,
          onSubmit: _submitCookies,
          // Leaving the screen cancels the login, as Back does.
          onCancel: () => Navigator.of(context).maybePop(),
        ),
      'complete' => _CompleteView(network: bridge.network, onDone: () => Navigator.of(context).pop()),
      _ => _ErrorView(
          message: "This sign-in method isn't supported in the app yet (${step.type}).",
          onRetry: null,
        ),
    };
  }

  /// "A phone can't scan its own screen": offer the network's code flow
  /// while a QR code is showing.
  LoginFlow? _alternativeFor(Bridge bridge) {
    if (_step?.displayType != 'qr') return null;
    return bridge.flows.where((f) => f.id != _flow?.id && f.id == 'phone').firstOrNull;
  }
}

class _FlowPicker extends StatelessWidget {
  const _FlowPicker({required this.bridge, required this.onPick});
  final Bridge bridge;
  final void Function(LoginFlow) onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('How do you want to link ${bridge.network}?', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (final f in bridge.flows)
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ListTile(
              title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(f.description),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onPick(f),
            ),
          ),
      ],
    );
  }
}

class _DisplayStep extends StatelessWidget {
  const _DisplayStep({
    required this.step,
    required this.bridge,
    required this.alternative,
    required this.onAlternative,
  });

  final LoginStep step;
  final Bridge bridge;
  final LoginFlow? alternative;
  final void Function(LoginFlow) onAlternative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = step.displayData;
    final Widget shown = switch (step.displayType) {
      'qr' when data != null => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: data, size: 260, backgroundColor: Colors.white),
        ),
      'qr' => _imageFromUrl(step.displayImageUrl),
      'code' when data != null => _Code(code: data),
      'emoji' when data != null => Text(data, style: const TextStyle(fontSize: 56)),
      _ => const CircularProgressIndicator(),
    };
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(child: shown),
        const SizedBox(height: 24),
        Text(step.instructions, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, height: 1.4)),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('Waiting for your phone', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
        if (alternative != null) ...[
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => onAlternative(alternative!),
            child: const Text('On this phone? Use phone number instead'),
          ),
        ],
      ],
    );
  }

  static Widget _imageFromUrl(String? url) {
    final data = url == null ? null : Uri.tryParse(url)?.data;
    if (data != null) return Image.memory(data.contentAsBytes(), width: 260, height: 260);
    return const CircularProgressIndicator();
  }
}

class _Code extends StatelessWidget {
  const _Code({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SelectableText(
          code,
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: 4, fontFeatures: [
            FontFeature.tabularFigures(),
          ]),
        ),
        TextButton.icon(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}

class _InputStep extends StatefulWidget {
  const _InputStep({required this.step, required this.busy, required this.onSubmit});
  final LoginStep step;
  final bool busy;
  final void Function(Map<String, String>) onSubmit;

  @override
  State<_InputStep> createState() => _InputStepState();
}

class _InputStepState extends State<_InputStep> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final f in widget.step.fields) f.id: TextEditingController(text: f.defaultValue ?? ''),
  };
  late final Map<String, String?> _selected = {
    for (final f in widget.step.fields)
      if (f.type == 'select') f.id: f.defaultValue ?? f.options.firstOrNull,
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    widget.onSubmit({
      for (final f in widget.step.fields)
        f.id: f.type == 'select' ? (_selected[f.id] ?? '') : _controllers[f.id]!.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.step.fields;
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (widget.step.instructions.isNotEmpty) ...[
            Text(widget.step.instructions, style: const TextStyle(fontSize: 15, height: 1.4)),
            const SizedBox(height: 20),
          ],
          for (final (i, f) in fields.indexed) ...[
            _field(f, last: i == fields.length - 1),
            const SizedBox(height: 14),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: widget.busy ? null : _submit,
            child: widget.busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _field(InputField f, {required bool last}) {
    if (f.type == 'select') {
      return DropdownButtonFormField<String>(
        initialValue: _selected[f.id],
        decoration: InputDecoration(labelText: f.name, helperText: f.description),
        items: [for (final o in f.options) DropdownMenuItem(value: o, child: Text(o))],
        onChanged: (v) => setState(() => _selected[f.id] = v),
      );
    }
    final (keyboard, hints, obscure) = switch (f.type) {
      'phone_number' => (TextInputType.phone, [AutofillHints.telephoneNumber], false),
      'email' => (TextInputType.emailAddress, [AutofillHints.email], false),
      'password' => (TextInputType.visiblePassword, [AutofillHints.password], true),
      '2fa_code' => (TextInputType.number, [AutofillHints.oneTimeCode], false),
      'url' || 'domain' => (TextInputType.url, <String>[], false),
      'username' => (TextInputType.text, [AutofillHints.username], false),
      _ => (TextInputType.text, <String>[], false),
    };
    final pattern = f.pattern == null ? null : RegExp(f.pattern!);
    return TextFormField(
      controller: _controllers[f.id],
      keyboardType: keyboard,
      autofillHints: hints,
      obscureText: obscure,
      autocorrect: false,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: last ? (_) => _submit() : null,
      decoration: InputDecoration(
        labelText: f.name,
        helperText: f.description,
        helperMaxLines: 3,
        hintText: f.type == 'phone_number' ? '+44 7700 900123' : null,
      ),
      validator: (v) {
        final value = v?.trim() ?? '';
        if (value.isEmpty) return f.optional ? null : 'Required';
        if (pattern != null && !pattern.hasMatch(value)) return "That doesn't look right";
        return null;
      },
    );
  }
}

class _CompleteView extends StatelessWidget {
  const _CompleteView({required this.network, required this.onDone});
  final String network;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_rounded, size: 64, color: Color(0xFF2EA043)),
          const SizedBox(height: 16),
          Text('$network linked', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Your chats will appear in the inbox as they sync.', textAlign: TextAlign.center),
          const SizedBox(height: 32),
          FilledButton(onPressed: onDone, child: const Text('Done')),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}
