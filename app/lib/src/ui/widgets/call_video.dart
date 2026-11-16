// A call's video: the contact's or the camera's newest frame, asked of the
// core once per screen frame at the size it's drawn, so a slow frame skips
// ahead rather than queueing. On iOS RingRTC's frames come natively: the
// contact's as a texture, the camera's preview as a platform view
// (app/ios/Runner/CallsBridge.swift).

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/calls.dart';
import '../../state/calls.dart';

class CallVideo extends ConsumerStatefulWidget {
  const CallVideo({super.key, required this.remote, this.fit = BoxFit.contain, this.placeholder});

  /// The contact's video, else the camera's.
  final bool remote;
  final BoxFit fit;

  /// Shown until the first frame.
  final Widget? placeholder;

  @override
  ConsumerState<CallVideo> createState() => _CallVideoState();
}

class _CallVideoState extends ConsumerState<CallVideo> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  ui.Image? _image;
  bool _asking = false;

  /// The drawn size in physical pixels, from the last layout.
  Size _pixels = Size.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _ask());
    if (!Platform.isIOS) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    if (_asking || _pixels.isEmpty) return;
    _asking = true;
    try {
      final frame = await ref
          .read(callProvider.notifier)
          .frame(remote: widget.remote, maxWidth: _pixels.width.ceil(), maxHeight: _pixels.height.ceil());
      if (frame == null || !mounted) return;
      final image = await _decode(frame);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
    } catch (e) {
      debugPrint('call video: $e');
    } finally {
      _asking = false;
    }
  }

  static Future<ui.Image> _decode(CallFrame frame) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(frame.rgba, frame.width, frame.height, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      if (!widget.remote) {
        return const UiKitView(viewType: 'switchboard/call-video', creationParamsCodec: StandardMessageCodec());
      }
      return ValueListenableBuilder<CallTexture?>(
        valueListenable: ref.read(callProvider.notifier).remoteTexture,
        builder: (context, texture, _) => texture == null
            ? widget.placeholder ?? const SizedBox.expand()
            : CallTextureView(texture: texture, fit: widget.fit),
      );
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedWidth && constraints.hasBoundedHeight;
        _pixels = bounded ? constraints.biggest * ratio : Size.zero;
        final image = _image;
        if (image == null) return widget.placeholder ?? const SizedBox.expand();
        return RawImage(image: image, fit: widget.fit, filterQuality: FilterQuality.medium);
      },
    );
  }
}

/// A video texture turned upright and fitted like an image.
class CallTextureView extends StatelessWidget {
  const CallTextureView({super.key, required this.texture, this.fit = BoxFit.contain});
  final CallTexture texture;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => SizedBox.expand(
        child: FittedBox(
          fit: fit,
          clipBehavior: Clip.hardEdge,
          child: RotatedBox(
            quarterTurns: texture.quarterTurns,
            child: SizedBox(
              width: texture.width.toDouble(),
              height: texture.height.toDouble(),
              child: Texture(textureId: texture.id, filterQuality: FilterQuality.medium),
            ),
          ),
        ),
      );
}
