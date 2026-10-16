#!/usr/bin/env python3
"""G62（spec §7.1-2）: 本のメタデータを連続して書き換え、1 件ごとの所要時間を測る（標準ライブラリだけ）。

  --mode cli    stacknest-cli set を N 回（CLI の起動を含む・2026-10-02 の事件と同じ形）
  --mode http   ローカルコントロールへ GET /libraries → PATCH を N 回（CLI と同じ 2 リクエスト）
  --mode stamp  スタンプの一括適用 1 回で N 冊（B5）

書き込む書庫は --library で名前か UUID を必ず指定する。名前が "g62-bench" で始まらない書庫には、
--allow-any-library を付けない限り書かない（作者の実書庫を書き換えないため・spec Q7 (a)）。
書く本は ID の大きい方から N 冊（合成の書庫では ID の順＝追加の順なので、追加日の降順で上に来る本）。
HTTP の API しか使わないので、直す前の main の build でも走る。
終了コードは、全件が成功（200）なら 0、タイムアウトか失敗（400 など）が 1 件でもあれば 1。
"""
import argparse
import csv
import json
import math
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULTS_DOMAIN = "app.shelfsmith.stacknest"
REQUEST_TIMEOUT_S = 60.0  # same as the URLRequest default (the CLI sets no timeout)
BENCH_PREFIX = "g62-bench"
DEFAULT_CLI = pathlib.Path(__file__).resolve().parents[2] / "dist" / "StackNest.app" / "Contents" / "Helpers" / "stacknest-cli"


def percentile(values, p):
    """最近傍の順位で p 分位（0〜100）を返す。空なら None。"""
    if not values:
        return None
    s = sorted(values)
    rank = max(1, math.ceil(p / 100.0 * len(s)))
    return s[rank - 1]


def summarize(rows):
    """rows: dict(elapsed=秒, status=HTTP の番号 か "timeout" か "exit N"/"error ...") の並び。"""
    done = [r["elapsed"] for r in rows if r["status"] != "timeout"]
    return {
        "count": len(rows),
        "ok": sum(1 for r in rows if r["status"] == 200),
        "timeouts": sum(1 for r in rows if r["status"] == "timeout"),
        "p50_s": percentile(done, 50),
        "p95_s": percentile(done, 95),
        "max_s": max(done) if done else None,
    }


def exit_code(summary):
    """全件が 200 なら 0。タイムアウトか失敗（400 など）が 1 件でもあれば 1（G62 pre-flight B1: 失敗を 0 で隠さない）。"""
    return 0 if summary["timeouts"] == 0 and summary["ok"] == summary["count"] else 1


# BookPatchDTO（Sources/LibraryServerAPI/DTOs.swift）の clear* 3 つは Optional でない Bool で、
# サーバは素の JSONDecoder で読む。鍵が欠けると PATCH は 400 になるので、どの本文にも False で入れる
# （G62 pre-flight B1。CLI は DTO 全体をエンコードするので最初から入っている）。
CLEAR_FLAGS = {"clearSeries": False, "clearVolume": False, "clearPageDirection": False}


def patch_body(field, i, salt):
    """i 件目に書く値。salt（実行ごとに変わる）を混ぜて本の今の値と違う値にする（同じ値だと「無変化」の経路になる）。
    rating だけは前の値を読まないので、合成の書庫では約 1/6 が同じ値になる（無変化の経路を混ぜて測るとき用）。"""
    if field == "series":
        values = {"series": f"{BENCH_PREFIX} {salt} s{i % 7}", "volume": float(i % 50 + 1)}
    elif field == "title":
        values = {"title": f"{BENCH_PREFIX} {salt} {(i * 7919) % 100000:05d}"}
    elif field == "rating":
        values = {"rating": (i % 5) + 1}
    else:
        raise ValueError(f"unknown field: {field}")
    return {**values, **CLEAR_FLAGS}


def cli_args(field, i, salt):
    """patch_body と同じ値を stacknest-cli set の引数にする（CLI の --volume は整数）。"""
    body = patch_body(field, i, salt)
    args = []
    for key in ("title", "series", "rating"):
        if key in body:
            args += [f"--{key}", str(body[key])]
    if "volume" in body:
        args += ["--volume", str(int(body["volume"]))]
    return args


def pick_library(libraries, wanted, allow_any):
    """GET /libraries の結果から、名前か UUID が wanted に一致する書庫を 1 つ選ぶ。0 件・複数・保護に当たれば SystemExit。"""
    matches = [lib for lib in libraries if lib.get("id") == wanted or lib.get("name") == wanted]
    if len(matches) != 1:
        raise SystemExit(f"--library {wanted!r} matched {len(matches)} libraries; give the exact name or UUID")
    lib = matches[0]
    if not allow_any and not lib["name"].startswith(BENCH_PREFIX):
        raise SystemExit(f"refusing to write to {lib['name']!r}: not a synthetic bench library "
                         f"(the name must start with {BENCH_PREFIX!r}, or pass --allow-any-library)")
    return lib


def read_default(key):
    out = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, key], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        raise SystemExit(f"cannot read {key} from {DEFAULTS_DOMAIN} (is local control enabled?)")
    return out.stdout.strip()


class Http:
    def __init__(self, port, token):
        self.base = f"http://127.0.0.1:{port}/api/v1"
        self.token = token

    def call(self, method, path, body=None, timeout=REQUEST_TIMEOUT_S):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()

    def libraries(self):
        _, raw = self.call("GET", "/libraries")
        return json.loads(raw)


def timed(fn):
    """fn() を 1 回走らせ、(開始, 終了, 状態) を返す。状態は HTTP の番号・"timeout"・"error ..."。"""
    start = time.time()
    try:
        status = fn()
    except urllib.error.HTTPError as e:
        status = e.code
    except (TimeoutError, urllib.error.URLError) as e:
        reason = getattr(e, "reason", e)
        status = "timeout" if isinstance(reason, TimeoutError) or "timed out" in str(reason) else f"error {reason}"
    return start, time.time(), status


def row(n, book_id, start, end, status):
    return {"index": n, "book_id": book_id, "start": start, "end": end, "elapsed": end - start, "status": status}


def run_http(http, lib, ids, field, salt):
    rows = []
    for n, book_id in enumerate(ids):
        def one(book_id=book_id, n=n):
            http.libraries()  # the CLI resolves the library with GET /libraries before every set
            status, _ = http.call("PATCH", f"/libraries/{lib['id']}/books/{book_id}", patch_body(field, n, salt))
            return status
        rows.append(row(n, book_id, *timed(one)))
    return rows


def run_cli(cli, lib, ids, field, salt):
    rows = []
    for n, book_id in enumerate(ids):
        start = time.time()
        try:
            p = subprocess.run([cli, "set", str(book_id), "--library", lib["id"], *cli_args(field, n, salt)],
                               capture_output=True, text=True, timeout=REQUEST_TIMEOUT_S * 2 + 10)
            end = time.time()
            if p.returncode == 0:
                status = 200
            elif end - start >= REQUEST_TIMEOUT_S - 0.5:
                status = "timeout"
            else:
                status = f"exit {p.returncode}"
        except subprocess.TimeoutExpired:
            end, status = time.time(), "timeout"
        rows.append(row(n, book_id, start, end, status))
    return rows


def run_stamp(http, lib, ids, salt):
    body = {"field": "genre", "value": f"{BENCH_PREFIX} {salt}", "bookIDs": ids}
    start, end, status = timed(lambda: http.call("POST", f"/libraries/{lib['id']}/books/stamp", body)[0])
    return [row(0, len(ids), start, end, status)]


def main(argv=None):
    ap = argparse.ArgumentParser(description="G62 burst benchmark (synthetic bench library only by default)")
    ap.add_argument("--mode", choices=["cli", "http", "stamp"], required=True)
    ap.add_argument("--library", required=True, help="library name or UUID (must start with g62-bench unless --allow-any-library)")
    ap.add_argument("--field", choices=["series", "title", "rating"], default="series")
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--csv", help="write one row per write to this CSV file")
    ap.add_argument("--cli", default=str(DEFAULT_CLI), help="path to stacknest-cli (cli mode)")
    ap.add_argument("--allow-any-library", action="store_true")
    ap.add_argument("--ignore-load", action="store_true", help="measure even when the 1-minute load average is above 2")
    ap.add_argument("--dry-run", action="store_true", help="resolve and print the library, write nothing")
    args = ap.parse_args(argv)

    load1 = os.getloadavg()[0]
    if load1 > 2.0 and not args.ignore_load and not args.dry_run:
        raise SystemExit(f"load average {load1:.2f} > 2: not measuring (G35 rule)")
    http = Http(read_default("local_control_port"), read_default("local_control_token"))
    lib = pick_library(http.libraries(), args.library, args.allow_any_library)
    count = min(args.count, lib["bookCount"])
    ids = list(range(lib["bookCount"], lib["bookCount"] - count, -1))
    print(json.dumps({"library": lib["name"], "uuid": lib["id"], "books": lib["bookCount"], "mode": args.mode,
                      "field": args.field, "count": count, "load1": round(load1, 2)}), flush=True)
    if args.dry_run:
        return 0
    salt = time.strftime("%H%M%S")
    if args.mode == "http":
        rows = run_http(http, lib, ids, args.field, salt)
    elif args.mode == "cli":
        rows = run_cli(args.cli, lib, ids, args.field, salt)
    else:
        rows = run_stamp(http, lib, ids, salt)
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["index", "book_id", "start", "end", "elapsed", "status"])
            w.writeheader()
            w.writerows(rows)
    summary = summarize(rows)
    summary["load1_before"] = round(load1, 2)
    summary["load1_after"] = round(os.getloadavg()[0], 2)
    print(json.dumps(summary))
    return exit_code(summary)


if __name__ == "__main__":
    sys.exit(main())
