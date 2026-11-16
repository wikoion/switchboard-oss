// The call above every screen: a ring card with Answer and Decline, then
// the call's state with Mute, Camera and Hang up. With video on either side
// it fills the window, and can shrink back to the card. It sits above the
// navigator, so its buttons are labelled rather than tooltipped (tooltips
// need the navigator's overlay).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/calls.dart';
import '../../state/calls.dart';
import '../../state/rooms.dart';
import 'avatar.dart';
import 'call_video.dart';

const _answerColor = Color(0xFF34C759);
const _hangUpColor = Color(0xFFFF3B30);

class CallPanel extends ConsumerStatefulWidget {
  const CallPanel({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<CallPanel> createState() => _CallPanelState();
}

class _CallPanelState extends ConsumerState<CallPanel> {
  /// The call shrunk to the card, so a new call starts full size.
  String? _shrunk;

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final full = call != null && call.hasVideo && _shrunk != call.update.callId;
    return Stack(
      children: [
        // Under a full-screen call nothing behind it is painted or animated.
        Offstage(offstage: full, child: TickerMode(enabled: !full, child: widget.child)),
        if (full)
          Positioned.fill(child: CallStage(call: call, onShrink: () => setState(() => _shrunk = call.update.callId)))
        else if (call != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: CallCard(
                      call: call,
                      onExpand: call.hasVideo ? () => setState(() => _shrunk = null) : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Runs a call action, saying so if it fails.
Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Call failed: $e')));
    }
  }
}

/// Redraws every second while connected, for the duration.
mixin _Ticking<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _tick;

  CallView get tickingCall;

  void syncTick() {
    final connected = tickingCall.phase == CallPhase.connected;
    if (connected && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!connected) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void initState() {
    super.initState();
    syncTick();
  }

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    syncTick();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

class CallCard extends ConsumerStatefulWidget {
  const CallCard({super.key, required this.call, this.onExpand});
  final CallView call;

  /// Fills the window with the call's video. Null without video.
  final VoidCallback? onExpand;

  @override
  ConsumerState<CallCard> createState() => _CallCardState();
}

class _CallCardState extends ConsumerState<CallCard> with _Ticking {
  @override
  CallView get tickingCall => widget.call;

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final room = ref.watch(roomSummaryProvider(call.roomId));
    final controller = ref.read(callProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Row(
          children: [
            if (room != null)
              RoomAvatar(room: room, size: 44)
            else
              const CircleAvatar(radius: 22, child: Icon(Icons.call_rounded)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room?.name ?? 'Signal call',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    callStatus(call),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (call.ringing) ...[
              _CallButton(
                label: 'Decline',
                icon: Icons.call_end_rounded,
                color: _hangUpColor,
                onPressed: () => _run(context, controller.hangUp),
              ),
              _CallButton(
                label: 'Answer',
                icon: Icons.call_rounded,
                color: _answerColor,
                onPressed: () => _run(context, controller.accept),
              ),
              if (call.update.video)
                _CallButton(
                  label: 'Video',
                  icon: Icons.videocam_rounded,
                  color: _answerColor,
                  onPressed: () => _run(context, () => controller.accept(video: true)),
                ),
            ] else if (call.phase != CallPhase.ended) ...[
              _MuteButton(call: call),
              _CameraButton(call: call),
              if (widget.onExpand != null)
                _CallButton(
                  label: 'Expand',
                  icon: Icons.open_in_full_rounded,
                  color: scheme.surfaceContainerHighest,
                  foreground: scheme.onSurface,
                  onPressed: widget.onExpand!,
                ),
              _CallButton(
                label: 'Hang up',
                icon: Icons.call_end_rounded,
                color: _hangUpColor,
                onPressed: () => _run(context, controller.hangUp),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The call filling the window: the contact's video, or their avatar while
/// their camera is off, with ours in a corner.
class CallStage extends ConsumerStatefulWidget {
  const CallStage({super.key, required this.call, required this.onShrink});
  final CallView call;
  final VoidCallback onShrink;

  @override
  ConsumerState<CallStage> createState() => _CallStageState();
}

class _CallStageState extends ConsumerState<CallStage> with _Ticking {
  @override
  CallView get tickingCall => widget.call;

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final room = ref.watch(roomSummaryProvider(call.roomId));
    final controller = ref.read(callProvider.notifier);
    const label = TextStyle(color: Colors.white70, fontSize: 11);
    final avatar = Center(
      child: room != null ? RoomAvatar(room: room, size: 120) : const Icon(Icons.person_rounded, size: 120),
    );
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: call.update.remoteVideo ? CallVideo(remote: true, placeholder: avatar) : avatar,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      room?.name ?? 'Signal call',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    Text(callStatus(call), style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
          if (call.video)
            Positioned(
              right: 16,
              bottom: 104,
              width: 200,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: const ColoredBox(
                  color: Color(0xFF202020),
                  child: CallVideo(remote: false, fit: BoxFit.cover),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _MuteButton(call: call, labelStyle: label),
                    _CameraButton(call: call, labelStyle: label),
                    _CallButton(
                      label: 'Shrink',
                      icon: Icons.close_fullscreen_rounded,
                      color: Colors.white24,
                      labelStyle: label,
                      onPressed: widget.onShrink,
                    ),
                    _CallButton(
                      label: 'Hang up',
                      icon: Icons.call_end_rounded,
                      color: _hangUpColor,
                      labelStyle: label,
                      onPressed: () => _run(context, controller.hangUp),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MuteButton extends ConsumerWidget {
  const _MuteButton({required this.call, this.labelStyle});
  final CallView call;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _CallButton(
      label: call.muted ? 'Unmute' : 'Mute',
      icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
      color: call.muted ? scheme.inverseSurface : scheme.surfaceContainerHighest,
      foreground: call.muted ? scheme.onInverseSurface : scheme.onSurface,
      labelStyle: labelStyle,
      onPressed: () => _run(context, ref.read(callProvider.notifier).toggleMute),
    );
  }
}

class _CameraButton extends ConsumerWidget {
  const _CameraButton({required this.call, this.labelStyle});
  final CallView call;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _CallButton(
      label: call.video ? 'Camera off' : 'Camera',
      icon: call.video ? Icons.videocam_rounded : Icons.videocam_off_rounded,
      color: call.video ? scheme.inverseSurface : scheme.surfaceContainerHighest,
      foreground: call.video ? scheme.onInverseSurface : scheme.onSurface,
      labelStyle: labelStyle,
      onPressed: () => _run(context, ref.read(callProvider.notifier).toggleVideo),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.foreground = Colors.white,
    this.labelStyle,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color foreground;
  final VoidCallback onPressed;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            onPressed: onPressed,
            icon: Icon(icon),
            style: IconButton.styleFrom(backgroundColor: color, foregroundColor: foreground),
          ),
          Text(
            label,
            style: labelStyle ?? TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
