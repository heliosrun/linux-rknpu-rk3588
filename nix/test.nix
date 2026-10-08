{
  lib,
  stdenv,
  cmake,
  # Pinned source checkouts (flake inputs), passed by callPackage.
  rocket-userspace,
  rknpu-submit,
}:
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