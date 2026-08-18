{
  lib,
  stdenv,
  cmake,
  pkg-config,
  fetchFromGitHub,
  systemd,
  bluez,
  openssl,
  zlib,
  libpulseaudio,
}:

# MagicPodsCore builds its C++ dependencies with CMake FetchContent, which needs
# network access at configure time — incompatible with the Nix build sandbox.
# We pre-fetch each dependency and feed it in via FETCHCONTENT_SOURCE_DIR_<NAME>
# with FETCHCONTENT_FULLY_DISCONNECTED=ON, leaving the upstream CMake untouched.
# Versions mirror dependencies/*/CMakeLists.txt.
let
  deps = {
    sdbus-cpp = fetchFromGitHub {
      owner = "Kistler-Group";
      repo = "sdbus-cpp";
      rev = "v1.6.0";
      hash = "sha256-h4eSVBm5VO5ol883dFKoilVGAcQVANNbFFVxKib2D48=";
    };
    uWebSockets = fetchFromGitHub {
      owner = "uNetworking";
      repo = "uWebSockets";
      rev = "v20.58.0";
      hash = "sha256-XSyX6iP+wlUcmBMdfvNyf/uFCzQGmogIS5ehUnRdWs0=";
    };
    uSockets = fetchFromGitHub {
      owner = "uNetworking";
      repo = "uSockets";
      rev = "v0.8.7";
      hash = "sha256-vf3xI5GOqTEZx8iXf133nQvhUylIRzJ3jGuNUcQk9nY=";
    };
    nlohmann_json = fetchFromGitHub {
      owner = "nlohmann";
      repo = "json";
      rev = "v3.11.3";
      hash = "sha256-7F0Jon+1oWL7uqet5i1IgHX0fUw/+z0QwEcA3zs5xHg=";
    };
    tomlplusplus = fetchFromGitHub {
      owner = "marzer";
      repo = "tomlplusplus";
      rev = "v3.4.0";
      hash = "sha256-h5tbO0Rv2tZezY58yUbyRVpsfRjY3i+5TPkkxr6La8M=";
    };
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "magicpodscore";
  version = "2.0.9";

  # Flake source tree (git-tracked files only), i.e. this repository root.
  src = lib.cleanSource ../.;

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  buildInputs = [
    systemd # libsystemd, for sdbus-c++
    bluez # libbluetooth
    openssl
    zlib
    libpulseaudio
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DFETCHCONTENT_SOURCE_DIR_SDBUS-CPP=${deps.sdbus-cpp}"
    "-DFETCHCONTENT_SOURCE_DIR_UWEBSOCKETS_CONTENT=${deps.uWebSockets}"
    "-DFETCHCONTENT_SOURCE_DIR_USOCKETS_CONTENT=${deps.uSockets}"
    "-DFETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=${deps.nlohmann_json}"
    "-DFETCHCONTENT_SOURCE_DIR_TOMLPLUSPLUS=${deps.tomlplusplus}"
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 magicpodscore "$out/bin/magicpodscore"
    runHook postInstall
  '';

  meta = {
    description = "Backend service exposing a WebSocket API for AirPods, Beats and Galaxy Buds";
    homepage = "https://github.com/steam3d/MagicPodsCore";
    license = lib.licenses.gpl3Only;
    mainProgram = "magicpodscore";
    platforms = lib.platforms.linux;
  };
})
