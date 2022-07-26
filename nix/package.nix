{ stdenv
, lib
, zig
}:

stdenv.mkDerivation rec {
  pname = "ghostty";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ zig ];

  buildInputs = [];

  dontConfigure = true;

  # preBuild = ''
  #   export HOME=$TMPDIR
  # '';

  installPhase = ''
    runHook preInstall
    zig build -Drelease-safe --prefix $out install
    runHook postInstall
  '';

  outputs = [ "out" ];

  meta = with lib; {
    homepage = "https://github.com/mitchellh/ghostty";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
  };
}
