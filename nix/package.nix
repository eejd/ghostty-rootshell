{ stdenv
, lib
, autoPatchelfHook
, libGL
, libX11
, zig
, git
, makeWrapper
}:

stdenv.mkDerivation rec {
  pname = "ghostty";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ autoPatchelfHook git makeWrapper zig ];

  buildInputs = [];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # Do nothing
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    export SDK_PATH=${src}/vendor/mach-sdk
    zig build -Drelease-safe \
      --cache-dir $TMP/cache \
      --global-cache-dir $TMP/global-cache \
      --prefix $out \
      install
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/ghostty \
      --prefix LD_LIBRARY_PATH : ${libGL}/lib \
      --prefix LD_LIBRARY_PATH : ${libX11}/lib
  '';

  outputs = [ "out" ];

  meta = with lib; {
    homepage = "https://github.com/mitchellh/ghostty";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
  };
}
