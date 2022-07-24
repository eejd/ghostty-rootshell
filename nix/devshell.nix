{ mkShell, lib, stdenv

, gdb
, glxinfo
, parallel
, pkg-config
, scdoc
, tracy
, vulkan-loader
, vttest
, zig

, bzip2
, fontconfig
, freetype
, libpng
, libGL
, libX11
, libXcursor
, libXext
, libXi
, libXinerama
, libXrandr
}: mkShell rec {
  name = "ghostty";

  nativeBuildInputs = [
    # For builds
    pkg-config
    scdoc
    zig

    # Testing
    gdb
    parallel
    tracy
    vttest
  ];

  buildInputs = [
    # TODO: non-linux
  ] ++ lib.optionals stdenv.isLinux [
    libX11
    libXcursor
    libXext
    libXi
    libXinerama
    libXrandr
  ];

  LD_LIBRARY_PATH = "${libX11}/lib:${libGL}/lib";
}
