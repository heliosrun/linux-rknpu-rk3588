#!/usr/bin/env python3
"""Regression tests: unsafe merged trees must be rejected by the DT validator."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

APPLIED, BASE = sys.argv[1:3]
CHECKER = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else pathlib.Path(__file__).with_name('check-applied-dt.py')
sys.argv = sys.argv[:1]


class UnsafeTreeTests(unittest.TestCase):
    def rejected(self, node, prop, values):
        with tempfile.TemporaryDirectory() as directory:
            tree = pathlib.Path(directory) / 'unsafe.dtb'
            shutil.copyfile(APPLIED, tree)
            subprocess.run(['fdtput', '-t', 'x', str(tree), node, prop,
                            *(f'{value:x}' for value in values)], check=True)
            result = subprocess.run([sys.executable, str(CHECKER), str(tree), BASE],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FAIL:', result.stderr)
            self.assertIn(prop, result.stderr)

    def test_no_unpowered_boot_rate_assignment(self):
        self.rejected('/npu@fdab0000', 'assigned-clock-rates', [1000000000])

    def test_max_rate_cannot_omit_required_voltage(self):
        self.rejected('/opp-table-rknpu/opp-1000000000', 'opp-microvolt', [800000])

    def test_single_bank_iommu_is_rejected(self):
        self.rejected('/iommu@fdab9000', 'reg', [0, 0xfdab9000, 0, 0x100])

    def test_npu_mapping_cannot_overlap_mmu_registers(self):
        self.rejected('/npu@fdab0000', 'reg', [0, 0xfdab0000, 0, 0x10000])

    def test_board_supply_cannot_be_dropped(self):
        self.rejected('/npu@fdab0000', 'npu-supply', [0])


if __name__ == '__main__':
    unittest.main()
