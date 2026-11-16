// Saving photos and videos from chats: to the Photos library on a phone, to
// the Downloads folder on desktop. Sharing them on a phone.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'layout.dart';
import 'media_bubbles.dart';

/// "Save to Photos" on a phone, "Save to Downloads" on desktop.
String get saveMediaLabel => isDesktop ? 'Save to Downloads' : 'Save to Photos';

IconData get saveMediaIcon => Icons.download_rounded;

/// [name] with an extension, so Photos and file managers know the type.
/// Bridges usually send a file name, but a caption can stand in for it.
String withExtension(String name, {String? mimetype, required bool video}) {
  final clean = name.trim().isEmpty ? (video ? 'video' : 'photo') : name.trim();
  if (RegExp(r'\.[A-Za-z0-9]{2,5}$').hasMatch(clean)) return clean;
  final ext = switch (mimetype) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/heic' => 'heic',
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    _ => video ? 'mp4' : 'jpg',
  };
  // Long captions make poor file names.
  final stem = clean.length > 60 ? clean.substring(0, 60).trimRight() : clean;
  return '$stem.$ext';
}

/// Downloads the original of a photo or video and saves it. Says how it
/// went in a snack bar.
Future<void> saveMedia(
  BuildContext context,
  WidgetRef ref, {
  required String mxc,
  required String name,
  String? mimetype,
  required bool video,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final fileName = withExtension(name, mimetype: mimetype, video: video);
  try {
    final file = await cachedMedia(ref, mxc, fileName);
    if (Platform.isIOS || Platform.isAndroid) {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        throw 'Switchboard isn\'t allowed to add to Photos. Turn it on in Settings → Switchboard → Photos.';
      }
      video ? await Gal.putVideo(file.path) : await Gal.putImage(file.path);
      messenger.showSnackBar(const SnackBar(content: Text('Saved to Photos')));
      return;
    }
    final dir = await getDownloadsDirectory() ?? Directory(Platform.environment['HOME'] ?? '.');
    final dest = await _freePath(dir, fileName);
    await file.copy(dest.path);
    messenger.showSnackBar(SnackBar(
      content: Text('Saved to ${dir.path.split('/').last}'),
      action: SnackBarAction(label: 'Show', onPressed: () => launchUrl(Uri.file(dir.path))),
    ));
  } on GalException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't save: ${e.type.message}")));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
  }
}

/// Whether this device can share files: share_plus can't on Linux.
bool get canShareMedia => !isDesktop;

const shareMediaIcon = Icons.ios_share_rounded;

/// Downloads the original of a photo or video and opens the share sheet
/// with it, next to [context]'s widget on an iPad.
Future<void> shareMedia(
  BuildContext context,
  WidgetRef ref, {
  required String mxc,
  required String name,
  String? mimetype,
  required bool video,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  try {
    final file = await cachedMedia(ref, mxc, withExtension(name, mimetype: mimetype, video: video));
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: mimetype)],
      sharePositionOrigin: origin,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
  }
}

/// `name`, or `name (2)` and so on if that's taken.
Future<File> _freePath(Directory dir, String name) async {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var file = File('${dir.path}/$name');
  for (var n = 2; await file.exists(); n++) {
    file = File('${dir.path}/$stem ($n)$ext');
  }
  return file;
}
