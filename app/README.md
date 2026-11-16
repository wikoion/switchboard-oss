# Switchboard app

Flutter UI over the Rust core in `../core`. iOS first, then Linux; see
[docs/m1-progress.md](../docs/m1-progress.md) and
[docs/m2-progress.md](../docs/m2-progress.md).

```sh
tool/sim-build.sh                 # debug Simulator build that signs in by itself
SB_SIM=<udid> tool/sim-shot.sh /accounts /tmp/shot.png
flutter test
flutter_rust_bridge_codegen generate   # after changing core/src/api
```

Linux:

```sh
flutter build linux --debug
tool/linux-shot.sh /accounts /tmp/shot.png 1280x800   # under Xvfb, restores the saved session
yay -Bi ../packaging/arch          # build and install the Arch package from committed HEAD
```

The Linux build needs `rustup`'s `stable` toolchain at 1.99.1 or later,
because cargokit builds the core with `rustup run stable`.
