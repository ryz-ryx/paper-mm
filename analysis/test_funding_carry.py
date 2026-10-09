"""Accounting checks for funding_carry.simulate on synthetic data (run: python -m unittest analysis/test_funding_carry.py)."""
import sys
import unittest
from pathlib import Path

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from funding_carry import APR, simulate, summarise  # noqa: E402

H = 100


def arrays(rate=1e-4, drift=0.0):
    fund = np.full((H + 1, 1), rate)
    fund[H] = np.nan
    opn = (100.0 * (1.0 + drift * np.arange(H + 1)))[:, None]
    return fund, opn


class TestSimulate(unittest.TestCase):
    def test_dn_funding_minus_fees(self):
        fund, opn = arrays()
        eq, cy, _ = simulate(fund * APR, fund, opn, 0, H, 10.0, "DN", 1.5)
        self.assertEqual(len(cy), 1)
        c = cy[0]
        self.assertEqual((c["entry_h"], c["exit_h"], c["forced"]), (1, H, True))
        # prints credited: hours 2..99 = 98 prints of 1 bp each on the perp notional; fees 4 x 1.5 bps (2 legs, entry+exit)
        self.assertAlmostEqual(c["funding_bps"], 98.0, places=6)
        self.assertAlmostEqual(c["fee_bps"], 6.0, places=6)
        self.assertAlmostEqual(c["net_bps"], 92.0, places=6)
        self.assertAlmostEqual(eq[-1] - eq[0], c["net_bps"] / 1e4 * 20.0, places=9)   # DN perp notional = 200/5/2

    def test_unhedged_price_pnl_and_identity(self):
        fund, opn = arrays(drift=-0.0001)           # price falls 1 bp per hour -> short gains
        eq, cy, _ = simulate(fund * APR, fund, opn, 0, H, 10.0, "UNH", 4.5)
        c = cy[0]
        ratio = opn[H, 0] / opn[1, 0]
        self.assertAlmostEqual(c["price_bps"], -(ratio - 1.0) * 1e4, places=6)
        self.assertGreater(c["price_bps"], 0)
        self.assertAlmostEqual(c["fee_bps"], 4.5 * (1.0 + ratio), places=6)
        self.assertAlmostEqual(eq[-1] - eq[0], c["net_bps"] / 1e4 * 40.0, places=9)   # UNH notional = 200/5

    def test_below_threshold_never_trades(self):
        fund, opn = arrays(rate=1e-5)               # 8.76 % APR < 10 %
        eq, cy, util = simulate(fund * APR, fund, opn, 0, H, 10.0, "DN", 1.5)
        self.assertEqual(cy, [])
        self.assertTrue(all(abs(e - 200.0) < 1e-12 for e in eq))
        self.assertEqual(util, 0.0)

    def test_exit_when_funding_drops_below_5pct(self):
        fund, opn = arrays()
        fund[40:H] = 1e-6                           # 0.876 % APR from hour 40
        eq, cy, _ = simulate(fund * APR, fund, opn, 0, H, 10.0, "DN", 1.5)
        c = cy[0]
        self.assertFalse(c["forced"])
        self.assertEqual(c["exit_h"], 41)           # decision after print 40, executed at the open of hour 41
        self.assertAlmostEqual(c["funding_bps"], 38.0 + 0.01, places=6)   # prints 2..39 at 1 bp, print 40 at 0.01 bp
        self.assertEqual(summarise(eq, cy, 0.1, H / 24)["cycles"], 1)


if __name__ == "__main__":
    unittest.main()
