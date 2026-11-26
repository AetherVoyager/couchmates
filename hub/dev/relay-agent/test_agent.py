"""Tests for agent.step: python -I test_agent.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent  # noqa: E402


class StepTest(unittest.TestCase):
    def test_totals_grow_from_counter_changes(self):
        state = {}
        t = 1_795_700_000  # 2026-11-26
        # First run only takes a baseline.
        self.assertEqual(agent.step(state, t, {"ctl_in": 100, "ctl_out": 50}, {"in": {}, "out": {}}, {"50000"}), 0)
        day = state["days"]["2026-11-26"]
        self.assertEqual((day["bytes_in"], day["sessions"]), (0, 0))
        # A minute of voice on 50000, a new allocation on 50002, cloudflared's port 50001 ignored.
        ports = {"in": {"50000": 300_000, "50001": 999_999}, "out": {"50000": 200_000, "50002": 10}}
        relaying = agent.step(state, t + 60, {"ctl_in": 1_100, "ctl_out": 2_050}, ports, {"50000", "50002"})
        self.assertEqual(relaying, 1)
        self.assertEqual(day["bytes_in"], 1_000 + 300_000)
        self.assertEqual(day["bytes_out"], 2_000 + 200_000 + 10)
        self.assertEqual(day["minutes"], 1.0)
        self.assertEqual(day["sessions"], 1)
        # Counters restarted (table re-added): the new value counts.
        agent.step(state, t + 120, {"ctl_in": 40, "ctl_out": 2_050}, ports, {"50000", "50002"})
        self.assertEqual(day["bytes_in"], 1_000 + 300_000 + 40)


if __name__ == "__main__":
    unittest.main()
