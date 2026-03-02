{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  hatchling,
  # Dependencies
  blessed,
  wcwidth,
  pyyaml,
  prettytable,
  requests,
}:
buildPythonPackage {
  pname = "ucs-detect";
  version = "unstable-2.0.2";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jquast";
    repo = "ucs-detect";
    rev = "44884c9581b57ed17d514b54adca07986576c2bf"; # tag 2.0.2
    hash = "sha256-pCJNrJN+SO0pGveNJuISJbzOJYyxP9Tbljp8PwqbgYU=";
  };

  dependencies = [
    blessed
    wcwidth
    pyyaml
    prettytable
    requests
  ];

  nativeBuildInputs = [hatchling];

  doCheck = false;
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    description = "Measures number of Terminal column cells of wide-character codes";
    homepage = "https://github.com/jquast/ucs-detect";
    license = licenses.mit;
    maintainers = [];
  };
}
