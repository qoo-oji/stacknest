#!/usr/bin/env python3
"""g62-burst.py の純粋な部分のテスト（標準ライブラリのみ）。"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("burst", ROOT / "Scripts" / "bench" / "g62-burst.py")
burst = importlib.util.module_from_spec(spec)
spec.loader.exec_module(burst)


class PercentileTests(unittest.TestCase):
    def test_nearest_rank(self):
        values = [float(i) for i in range(1, 201)]  # 1..200
        self.assertEqual(burst.percentile(values, 50), 100.0)
        self.assertEqual(burst.percentile(values, 95), 190.0)
        self.assertEqual(burst.percentile(values, 100), 200.0)

    def test_empty(self):
        self.assertIsNone(burst.percentile([], 95))


class SummarizeTests(unittest.TestCase):
    def test_timeouts_are_counted_and_left_out_of_the_times(self):
        rows = [{"elapsed": 0.1, "status": 200}, {"elapsed": 60.0, "status": "timeout"},
                {"elapsed": 0.3, "status": 200}]
        s = burst.summarize(rows)
        self.assertEqual((s["count"], s["ok"], s["timeouts"]), (3, 2, 1))
        self.assertEqual(s["max_s"], 0.3)

    def test_any_write_that_is_not_ok_fails_the_run(self):
        # G62 pre-flight B1: 400 などの失敗はタイムアウトでなくても終了コードを 1 にする（静かに 0 で終わらない）。
        all_ok = [{"elapsed": 0.1, "status": 200}, {"elapsed": 0.2, "status": 200}]
        self.assertEqual(burst.exit_code(burst.summarize(all_ok)), 0)
        one_bad = all_ok + [{"elapsed": 0.1, "status": 400}]
        self.assertEqual(burst.exit_code(burst.summarize(one_bad)), 1)
        one_timeout = all_ok + [{"elapsed": 60.0, "status": "timeout"}]
        self.assertEqual(burst.exit_code(burst.summarize(one_timeout)), 1)


class ValueTests(unittest.TestCase):
    def test_every_run_and_every_write_gets_a_new_value(self):
        self.assertNotEqual(burst.patch_body("series", 3, "100000"), burst.patch_body("series", 3, "100001"))
        self.assertNotEqual(burst.patch_body("title", 1, "x"), burst.patch_body("title", 2, "x"))

    def test_cli_args_mirror_the_patch(self):
        self.assertEqual(burst.cli_args("series", 0, "s"), ["--series", "g62-bench s s0", "--volume", "1"])
        self.assertEqual(burst.cli_args("rating", 0, "s"), ["--rating", "1"])

    def test_every_patch_body_carries_the_required_clear_flags(self):
        # G62 pre-flight B1: BookPatchDTO の clearSeries・clearVolume・clearPageDirection は Optional でない Bool。
        # 鍵が欠けると PATCH は 400 になる。どの field でも 3 つとも False で送る。
        for field in ("series", "title", "rating"):
            body = burst.patch_body(field, 0, "s")
            for key in ("clearSeries", "clearVolume", "clearPageDirection"):
                self.assertIs(body.get(key), False, f"{field}: {key}")


class PickLibraryTests(unittest.TestCase):
    LIBS = [{"id": "U1", "name": "g62-bench", "bookCount": 12441},
            {"id": "U2", "name": "My comics", "bookCount": 9000}]

    def test_by_name_and_by_uuid(self):
        self.assertEqual(burst.pick_library(self.LIBS, "g62-bench", False)["id"], "U1")
        self.assertEqual(burst.pick_library(self.LIBS, "U1", False)["id"], "U1")

    def test_refuses_a_library_that_is_not_the_bench(self):
        with self.assertRaises(SystemExit):
            burst.pick_library(self.LIBS, "My comics", False)
        self.assertEqual(burst.pick_library(self.LIBS, "My comics", True)["id"], "U2")

    def test_unknown_library(self):
        with self.assertRaises(SystemExit):
            burst.pick_library(self.LIBS, "nope", False)


if __name__ == "__main__":
    unittest.main()
