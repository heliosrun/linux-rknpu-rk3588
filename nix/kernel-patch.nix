{ lib }:
{
  name = "rk3588-rknpu-four-bank-iommu";
  patch = ../linux-integration/rk3588-npu-iommu.patch;
  structuredExtraConfig = with lib.kernel; {
    PM = yes;
    PM_GENERIC_DOMAINS = yes;
    PM_GENERIC_DOMAINS_OF = yes;
    PM_DEVFREQ = yes;
    PM_OPP = yes;
    DEVFREQ_GOV_PERFORMANCE = yes;
    THERMAL = yes;
    THERMAL_OF = yes;
    DEVFREQ_THERMAL = yes;
    ROCKCHIP_IOMMU = yes;
  };
}
