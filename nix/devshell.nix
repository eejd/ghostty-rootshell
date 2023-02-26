{ mkShell, lib, stdenv

, flatpak-builder
, fpm
, gdb
, glxinfo
, nodejs
, parallel
, pkg-config
, python
, scdoc
, tracy
, valgrind
, vulkan-loader
, vttest
, wabt
, wasmtime
, wraptest
, zig
, zip
, llvmPackages_latest

, bzip2
, expat
, fontconfig
, freetype
, glib
, gtk4
, harfbuzz
, libpng
, libGL
, libuv
, libX11
, libXcursor
, libXext
, libXi
, libXinerama
, libXrandr
, pixman
, zlib
}:
let
  # See package.nix. Keep in sync.
  rpathLibs = [
    libGL
  ] ++ lib.optionals stdenv.isLinux [
    bzip2
    expat
    fontconfig
    freetype
    harfbuzz
    libpng
    libuv
    zlib

    libX11
    libXcursor
    libXi
    libXrandr

    gtk4
    glib
  ];
in mkShell rec {
  name = "ghostty";

  nativeBuildInputs = [
    # For builds
    flatpak-builder
    fpm
    llvmPackages_latest.llvm
    pkg-config
    scdoc
    zig
    zip

    # For web and wasm stuff
    nodejs

    # Testing
    gdb
    parallel
    python
    tracy
    vttest

    # wasm
    wabt
    wasmtime
  ] ++ lib.optionals stdenv.isLinux [
    valgrind
    wraptest
  ];

  buildInputs = [
    # TODO: non-linux
  ] ++ lib.optionals stdenv.isLinux [
    bzip2
    expat
    fontconfig
    freetype
    harfbuzz
    libpng
    libuv
    pixman
    zlib

    libX11
    libXcursor
    libXext
    libXi
    libXinerama
    libXrandr

    # Only needed for GTK builds
    gtk4
    glib
  ];

  # This should be set onto the rpath of the ghostty binary if you want
  # it to be "portable" across the system.
  LD_LIBRARY_PATH = lib.makeLibraryPath rpathLibs;
}
