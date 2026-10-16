#!/usr/bin/env python3
"""g62-burst.py の純粋な部分のテスト（標準ライブラリのみ）。動いているアプリには一切つながない。"""
import csv
import http.client
import importlib.util
import os
import pathlib
import socket
import stat
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

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


class FakeHttp:
    """Http の代わり。PATCH/POST ごとに outcomes の先頭を 1 つ使う（数なら状態、例外なら投げる）。"""

    def __init__(self, outcomes):
        self.outcomes = list(outcomes)

    def libraries(self):
        return []

    def call(self, method, path, body=None, timeout=None):
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome, b"{}"


LIB = {"id": "U1", "name": "g62-bench", "bookCount": 3}


def _noop(_row):
    pass


class TimedTests(unittest.TestCase):
    """G62 follow-up 1: 接続の切断などで計測全体を落とさず、理由つきの失敗 1 件として数える。"""

    def status_of(self, exc):
        def fn():
            raise exc
        return burst.timed(fn)[2]

    def test_a_dropped_connection_is_a_failed_write_with_a_reason(self):
        status = self.status_of(http.client.RemoteDisconnected("Remote end closed connection without response"))
        self.assertTrue(status.startswith("error RemoteDisconnected"), status)
        status = self.status_of(ConnectionResetError(54, "Connection reset by peer"))
        self.assertTrue(status.startswith("error ConnectionResetError"), status)
        status = self.status_of(http.client.IncompleteRead(b"partial"))
        self.assertTrue(status.startswith("error IncompleteRead"), status)
        status = self.status_of(OSError(65, "No route to host"))
        self.assertTrue(status.startswith("error OSError"), status)

    def test_timeouts_and_http_errors_keep_their_meaning(self):
        self.assertEqual(self.status_of(TimeoutError("timed out")), "timeout")
        self.assertEqual(self.status_of(socket.timeout("timed out")), "timeout")
        self.assertEqual(self.status_of(urllib.error.URLError(TimeoutError("timed out"))), "timeout")
        self.assertEqual(self.status_of(urllib.error.HTTPError("http://x", 400, "Bad Request", {}, None)), 400)
        self.assertTrue(self.status_of(urllib.error.URLError(ConnectionRefusedError(61, "refused"))).startswith("error"))

    def test_a_dropped_connection_does_not_stop_the_run(self):
        fake = FakeHttp([200, http.client.RemoteDisconnected("closed"), 200])
        rows = burst.run_http(fake, LIB, [3, 2, 1], "series", "s", _noop)
        self.assertEqual([r["book_id"] for r in rows], [3, 2, 1])
        self.assertEqual(rows[0]["status"], 200)
        self.assertTrue(str(rows[1]["status"]).startswith("error RemoteDisconnected"))
        self.assertEqual(burst.exit_code(burst.summarize(rows)), 1)


class CsvRowsTests(unittest.TestCase):
    """G62 follow-up 2: 行は書けたそばから CSV に出す（途中で落ちても、それまでの行は残る）。"""

    def read_rows(self, path):
        with open(path, newline="") as f:
            return list(csv.DictReader(f))

    def test_each_row_is_on_disk_before_the_next_write(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "run.csv")
            with burst.CsvRows(path) as sink:
                sink.add(burst.row(0, 3, 1.0, 1.5, 200))
                on_disk = self.read_rows(path)  # still open: must already be flushed
            self.assertEqual(len(on_disk), 1)
            self.assertEqual(on_disk[0]["book_id"], "3")
            self.assertEqual(on_disk[0]["status"], "200")

    def test_rows_written_before_a_crash_survive(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "run.csv")
            fake = FakeHttp([200, RuntimeError("unexpected")])
            with self.assertRaises(RuntimeError):
                with burst.CsvRows(path) as sink:
                    burst.run_http(fake, LIB, [3, 2, 1], "series", "s", sink.add)
            rows = self.read_rows(path)
            self.assertEqual([r["index"] for r in rows], ["0"])

    def test_no_path_writes_nothing(self):
        with burst.CsvRows(None) as sink:
            sink.add(burst.row(0, 3, 1.0, 1.5, 200))  # must not raise


class CliBinaryTests(unittest.TestCase):
    """G62 follow-up 3: --cli のバイナリが無いときは 1 行の説明で非 0 終了（トレースバックにしない）。"""

    def test_a_missing_binary_is_refused_with_one_line(self):
        with self.assertRaises(SystemExit) as cm:
            burst.check_cli("/nonexistent/stacknest-cli")
        message = str(cm.exception.code)
        self.assertIn("/nonexistent/stacknest-cli", message)
        self.assertIn("--cli", message)
        self.assertNotIn("\n", message)

    def test_a_file_that_is_not_executable_is_refused(self):
        with tempfile.NamedTemporaryFile() as f:
            os.chmod(f.name, stat.S_IRUSR | stat.S_IWUSR)
            with self.assertRaises(SystemExit):
                burst.check_cli(f.name)

    def test_an_executable_passes(self):
        burst.check_cli(sys.executable)

    def test_main_refuses_before_reading_defaults_or_calling_the_app(self):
        with mock.patch.object(burst, "read_default", side_effect=AssertionError("read defaults")), \
                mock.patch.object(burst, "Http", side_effect=AssertionError("called the app")), \
                mock.patch.object(burst.os, "getloadavg", return_value=(0.0, 0.0, 0.0)):
            with self.assertRaises(SystemExit) as cm:
                burst.main(["--mode", "cli", "--library", "g62-bench", "--cli", "/nonexistent/stacknest-cli"])
        self.assertIn("/nonexistent/stacknest-cli", str(cm.exception.code))

    def test_run_cli_records_a_failed_launch_instead_of_crashing(self):
        rows = burst.run_cli("/nonexistent/stacknest-cli", LIB, [3], "series", "s", _noop)
        self.assertEqual(len(rows), 1)
        self.assertTrue(str(rows[0]["status"]).startswith("error FileNotFoundError"), rows[0]["status"])


class SaltTests(unittest.TestCase):
    """G62 follow-up 4: 同じ秒のうちに 2 回走らせても、書く値が前の回と変わる。"""

    def test_salt_changes_within_the_same_second(self):
        t = 1_760_000_000.25
        self.assertNotEqual(burst.make_salt(t), burst.make_salt(t + 0.001))
        self.assertNotEqual(burst.patch_body("series", 0, burst.make_salt(t)),
                            burst.patch_body("series", 0, burst.make_salt(t + 0.001)))

    def test_salt_is_stable_for_the_same_instant(self):
        t = 1_760_000_000.5
        self.assertEqual(burst.make_salt(t), burst.make_salt(t))


class StampRowTests(unittest.TestCase):
    """G62 follow-up 5: スタンプの 1 行は、何冊に書いたかを books 列に持つ（book_id に冊数を入れない）。"""

    def test_stamp_row_counts_books_honestly(self):
        rows = burst.run_stamp(FakeHttp([200]), LIB, [3, 2, 1], "s", _noop)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["books"], 3)
        self.assertIsNone(rows[0]["book_id"])
        self.assertEqual(rows[0]["status"], 200)

    def test_per_book_rows_count_one_book(self):
        rows = burst.run_http(FakeHttp([200]), LIB, [3], "series", "s", _noop)
        self.assertEqual((rows[0]["book_id"], rows[0]["books"]), (3, 1))


if __name__ == "__main__":
    unittest.main()
