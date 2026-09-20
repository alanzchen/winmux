import runpy
import unittest
from pathlib import Path


cpu_percent = runpy.run_path(str(Path(__file__).with_name("measure-idle-cpu.py")))["cpu_percent"]


class CpuMeasurementTest(unittest.TestCase):
    def test_apple_silicon_ticks_are_converted_to_nanoseconds(self):
        self.assertAlmostEqual(cpu_percent(24_000_000, 1, 125, 3), 100)
        self.assertAlmostEqual(cpu_percent(240_000, 1, 125, 3), 1)

    def test_percentage_uses_one_core_and_the_actual_interval(self):
        self.assertAlmostEqual(cpu_percent(12_000_000_000, 5, 1, 1), 240)

    def test_invalid_counter_or_clock_data_cannot_pass_the_budget(self):
        for args in [(-1, 5, 125, 3), (1, 0, 125, 3), (1, float("nan"), 125, 3),
                     (1, 5, 0, 3), (1, 5, 125, 0)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                cpu_percent(*args)


if __name__ == "__main__":
    unittest.main()
