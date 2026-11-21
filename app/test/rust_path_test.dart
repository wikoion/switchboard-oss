@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// tool/rust-path.sh, sourced by the release script, puts Homebrew's rustup
/// directory on PATH when the build could not find rustc otherwise. These run
/// it against made-up installs under a temporary directory, with a PATH of
/// those directories only, so the machine's own Rust install plays no part.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rust_path_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Makes an executable file at [path] under the temporary directory and
  /// returns the directory it is in.
  String tool(String path) {
    final file = File('${tmp.path}/$path')..createSync(recursive: true);
    file.writeAsStringSync('#!/bin/sh\n');
    Process.runSync('/bin/chmod', ['+x', file.path]);
    return file.parent.path;
  }

  /// Sources the script the way tool/testflight.sh does, under `set -eu`, and
  /// returns the PATH it leaves and where rustc is found on it.
  ({String path, String rustc}) source(String path, {String? cargoHome}) {
    final result = Process.runSync(
      '/bin/sh',
      [
        '-c',
        'set -eu; . tool/rust-path.sh; echo "\$PATH"; command -v rustc || echo none',
      ],
      environment: {
        'PATH': path,
        'HOME': '${tmp.path}/home',
        'CARGO_HOME': ?cargoHome,
      },
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final lines = (result.stdout as String).trim().split('\n');
    return (path: lines[0], rustc: lines[1]);
  }

  test("adds Homebrew's rustup directory when rustc is out of reach", () {
    final bin = tool('brew/bin/rustup');
    final keg = tool('brew/opt/rustup/bin/rustc');
    final other = tool('other/bin/sometool');

    final after = source('$other:$bin');

    expect(after.path, '$other:$bin:$keg');
    expect(after.rustc, '$keg/rustc');
  });

  test('leaves PATH alone when rustc is on it', () {
    final bin = tool('brew/bin/rustup');
    tool('brew/opt/rustup/bin/rustc');
    final own = tool('own/bin/rustc');

    final after = source('$bin:$own');

    expect(after.path, '$bin:$own');
    expect(after.rustc, '$own/rustc');
  });

  test("leaves PATH alone when Cargo's bin directory has a rustc", () {
    // rustup itself puts this directory on PATH for the build.
    final bin = tool('brew/bin/rustup');
    tool('brew/opt/rustup/bin/rustc');

    tool('home/.cargo/bin/rustc');
    expect(source(bin).path, bin);

    Directory('${tmp.path}/home').deleteSync(recursive: true);
    tool('cargo/bin/rustc');
    expect(source(bin, cargoHome: '${tmp.path}/cargo').path, bin);
  });

  test('leaves PATH alone when rustup is not from Homebrew', () {
    final bin = tool('plain/bin/rustup');
    expect(source(bin).path, bin);
    expect(source(bin).rustc, 'none');
  });

  test('leaves PATH alone when there is no rustup', () {
    final other = tool('other/bin/sometool');
    expect(source(other).path, other);
  });

  test('the TestFlight script sources it before it builds', () {
    final lines = File('tool/testflight.sh').readAsLinesSync();
    final sourced = lines.indexOf('. tool/rust-path.sh');
    final build = lines.indexWhere((l) => l.contains('xcodebuild archive'));
    expect(sourced, isNot(-1));
    expect(build, greaterThan(sourced));
  });
}
