{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  flit-core,
  six,
  wcwidth,
}:
buildPythonPackage {
  pname = "blessed";
  version = "unstable-1.31";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "blessed";
    rev = "9d2580b5f800a26a19cebe7119163be5e9ae58e9"; # tag 1.31
    hash = "sha256-Nn+aiDk0Qwk9xAvAqtzds/WlrLAozjPL1eSVNU75tJA=";
  };

  build-system = [flit-core];

  propagatedBuildInputs = [
    wcwidth
    six
  ];

  doCheck = false;
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    homepage = "https://github.com/jquast/blessed";
    description = "Thin, practical wrapper around terminal capabilities in Python";
    maintainers = [];
    license = licenses.mit;
  };
}
