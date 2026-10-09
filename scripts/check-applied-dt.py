#!/usr/bin/env python3
"""Validate the merged RK3588 tree, including phandles rather than node names."""
import subprocess
import sys


def get(tree, node, prop, numeric=False):
    args = ['fdtget', '-t', 'x' if numeric else 's', tree, node, prop]
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    if numeric:
        return [int(value, 16) for value in result.stdout.split()]
    return result.stdout.strip()


def check(tree, node, prop, expected):
    actual = get(tree, node, prop, isinstance(expected, list))
    if actual != expected:
        raise ValueError(f'{node} {prop}: expected {expected!r}, got {actual!r}')
    print(f'ok: {node} {prop}')


def validate(tree, base):
    npu = '/npu@fdab0000'
    mmu = '/iommu@fdab9000'
    check(tree, npu, 'compatible', 'rockchip,rk3588-rknpu')
    check(tree, npu, 'status', 'okay')
    check(tree, npu, 'assigned-clock-rates', [0])
    check(tree, npu, 'reg', [cell for addr in (0xfdab0000, 0xfdac0000, 0xfdad0000)
                             for cell in (0, addr, 0, 0x9000)])
    check(tree, mmu, 'compatible', 'rockchip,rk3588-rknpu-iommu')
    check(tree, mmu, 'status', 'okay')
    check(tree, mmu, 'reg', [cell for addr in (0xfdab9000, 0xfdaba000, 0xfdaca000, 0xfdada000)
                             for cell in (0, addr, 0, 0x100)])
    check(tree, mmu, 'clock-names', 'aclk0 iface0 aclk1 iface1 aclk2 iface2')
    check(tree, mmu, 'power-domain-names', 'npu0 npu1 npu2')
    domains = get(tree, npu, 'power-domains', True)
    if len(domains) != 6 or len(set(domains[1::2])) != 3:
        raise ValueError('NPU must have three distinct power domains')
    check(tree, mmu, 'power-domains', domains)
    check(tree, npu, 'iommus', get(tree, mmu, 'phandle', True))
    clocks = get(tree, npu, 'clocks', True)
    check(tree, npu, 'clock-names', 'clk_npu aclk0 aclk1 aclk2 hclk0 hclk1 hclk2 '
                                 'pclk pclk_grf pclk_pvtm clk_pvtm clk_core_pvtm hclk_root')
    if len(clocks) != 26:
        raise ValueError('NPU must supply all thirteen clock phandles')
    # MMU clocks must be the same core bus clocks held by the consumer.
    mmu_clocks = [cell for index in (1, 4, 2, 5, 3, 6)
                  for cell in clocks[2 * index:2 * index + 2]]
    check(tree, mmu, 'clocks', mmu_clocks)
    check(tree, npu, 'interrupts', [cell for irq in (110, 111, 112) for cell in (0, irq, 4, 0)])
    check(tree, mmu, 'interrupts', get(tree, npu, 'interrupts', True))
    for node in ('/npu@fdac0000', '/npu@fdad0000', '/iommu@fdaca000', '/iommu@fdada000'):
        check(tree, node, 'status', 'disabled')
    for prop in ('npu-supply', 'sram-supply'):
        check(tree, npu, prop, get(base, npu, prop, True))
    opp = '/opp-table-rknpu'
    check(tree, npu, 'operating-points-v2', get(tree, opp, 'phandle', True))
    for mhz, uv in ((200, 800000), (300, 800000), (400, 800000), (500, 825000),
                    (600, 850000), (700, 875000), (800, 900000), (900, 925000), (1000, 950000)):
        node = f'{opp}/opp-{mhz * 1000000}'
        check(tree, node, 'opp-hz', [0, mhz * 1000000])
        check(tree, node, 'opp-microvolt', [uv])
    check(tree, npu, '#cooling-cells', [2])
    thermal = '/thermal-zones/npu-thermal'
    trip = f'{thermal}/trips/npu-throttle'
    check(tree, thermal, 'polling-delay', [1000])
    check(tree, trip, 'temperature', [85000])
    check(tree, trip, 'type', 'passive')
    check(tree, f'{thermal}/cooling-maps/map-rknpu', 'trip', get(tree, trip, 'phandle', True))
    check(tree, f'{thermal}/cooling-maps/map-rknpu', 'cooling-device',
          get(tree, npu, 'phandle', True) + [0xffffffff, 0xffffffff])
    # Preserve the upstream critical trip as the final protection.
    check(tree, f'{thermal}/trips/npu-crit', 'temperature', [115000])
    print('ALL DT CHECKS PASSED')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3:
            raise ValueError('usage: check-applied-dt.py <applied-dtb> <base-dtb>')
        validate(*sys.argv[1:])
    except (ValueError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
