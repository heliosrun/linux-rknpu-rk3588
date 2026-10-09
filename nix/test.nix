{
  lib,
  stdenv,
  cmake,
  fetchFromGitHub,
  # Must match hardware.rknpu.npuClockHz for the configuration under
  # test; the module passes its (assertion-locked) option value here.
  expectedHz ? 200000000,
}:

let
  # Pinned test sources. Bump rev + hash together.
  rocket-userspace = fetchFromGitHub {
    owner = "gregordinary";
    repo = "rocket-userspace";
    rev = "f86cf52c666b4eddadc17d80d6c558b4067c0d6b";
    hash = "sha256-XjkRo1iwratu4ATtY3PX8V5AJaSzDulSJB9yZyeyLJE=";
  };
  rknpu-submit = fetchFromGitHub {
    owner = "gregordinary";
    repo = "rknpu-submit";
    rev = "6b144b19bb6700f96fc1638ccc7f20ad8719d527";
    hash = "sha256-hcg+L9hpQb6I7JtyRdB9Tqfb6Z7hM37sH38SPKSom1Q=";
  };
in
stdenv.mkDerivation {
  pname = "rknpu-test";
  version = "0.1.0";

  dontUnpack = true;
  # The buildPhase drives cmake directly (two separate trees).
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ cmake ];

  buildPhase = ''
    runHook preBuild

    cmake -S ${rknpu-submit} -B provider-build \
      -DROCKETNPU_INCLUDE_DIR=${rocket-userspace}/include \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build provider-build -j$NIX_BUILD_CORES

    cmake -S ${rocket-userspace} -B consumer-build \
      -DROCKETNPU_PROVIDER=external \
      -DROCKETNPU_PROVIDER_LIB=$PWD/provider-build/librknpu-submit.a \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build consumer-build -j$NIX_BUILD_CORES \
      --target matmul_fp16_rocket

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    install -Dm755 consumer-build/matmul_fp16_rocket -t $out/bin/
    install -Dm755 ${./npu-smoke-test.sh} $out/bin/npu-smoke-test
    # Bake the configured expectation into the installed script's default
    # (the EXPECTED_HZ env override still wins, for ad-hoc testing).
    substitute $out/bin/npu-smoke-test $out/bin/npu-smoke-test \
      --replace-fail 'EXPECTED_HZ:=200000000' "EXPECTED_HZ:=${toString expectedHz}"
    substitute ${./rknpu-test-runner.sh} $out/bin/rknpu-test \
      --replace-fail @BINDIR@ "$out/bin"
    chmod 755 $out/bin/rknpu-test

    runHook postInstall
  '';

  meta = {
    description = "NPU bring-up tests: fp16 matmul runner + smoke checks (RK3588 hardware only)";
    homepage = "https://github.com/heliosrun/linux-rknpu-rk3588";
    license = with lib.licenses; [ gpl2Only gpl3Plus ];
    platforms = [ "aarch64-linux" ];
  };
}