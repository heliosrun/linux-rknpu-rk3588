{
  lib,
  stdenv,
  kernel,
  kernelModuleMakeFlags,
}:

stdenv.mkDerivation {
  pname = "rknpu";
  version = "0.9.8-${kernel.version}";

  src = ../driver;

  hardeningDisable = [ "pic" ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = kernelModuleMakeFlags ++ [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  enableParallelBuilding = true;

  installPhase = ''
    runHook preInstall

    install -Dm644 rknpu.ko "$out/lib/modules/${kernel.modDirVersion}/misc/rknpu.ko"

    runHook postInstall
  '';

  meta = {
    description = "Rockchip RKNPU NPU driver (v0.9.8 ported to mainline)";
    longDescription = ''
      GPL-2.0 Rockchip NPU driver v0.9.8 (vendor source from
      armbian/linux-rockchip rk-6.1-rkr6.1), ported to mainline 7.x:
      mainline API support, OPP/devfreq up to 1 GHz with 200 MHz parking,
      and a companion kernel patch for four-bank multicore DMA isolation.
    '';
    homepage = "https://github.com/heliosrun/linux-rknpu-rk3588";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
