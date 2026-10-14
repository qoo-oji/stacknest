"""Scripts/check-private-identifiers.sh の試験（一時の git リポジトリと一時の検査語の一覧で動かす）。

止まるべき場面で止まることを確かめる: 一覧が無い・空、ファイル全体、途中のコミットで足して後で消した行、
UTF-8 として読めない行の後ろ、grep・awk の失敗、ほかの remote にだけあるコミットを新しい ref で push するとき。
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / "check-private-identifiers.sh"
HOOK = Path(__file__).resolve().parents[1] / "githooks" / "pre-push"
ZERO = "0" * 40
# 本物の識別子は使わない（一覧はリポジトリの外にあり、中身そのものが識別子なので）
WORD = "zqx" + "-private-word"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pid-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.list = self.tmp / "identifiers"
        self.list.write_text("# comment\n\n" + WORD + "\n")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ)
        self.env.update({
            "STACKNEST_PRIVATE_IDENTIFIERS_FILE": str(self.list),
            "GIT_AUTHOR_NAME": "tester", "GIT_AUTHOR_EMAIL": "tester@example.invalid",
            "GIT_COMMITTER_NAME": "tester", "GIT_COMMITTER_EMAIL": "tester@example.invalid",
            "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(self.tmp),
        })
        self.git("init", "-q", "-b", "main")

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=check,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, name, data, message="change"):
        path = self.repo / name
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
        self.git("add", name)
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_script(self, *args, stdin="", env=None):
        result = subprocess.run(["bash", str(SCRIPT), *args], cwd=self.repo, env=env or self.env,
                                input=stdin, capture_output=True, encoding="utf-8", errors="replace")
        return result.returncode, result.stderr

    def fake(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        env = dict(self.env)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return env

    def added_then_removed(self):
        """識別子を足すコミットと消すコミットを作り、（始まり, 先端）を返す。先端のファイル全体には残らない。"""
        base = self.commit("a.txt", "clean\n", "start")
        self.commit("a.txt", "clean\n" + WORD + "\n", "add")
        tip = self.commit("a.txt", "clean\n", "remove")
        return base, tip


class ListTests(Base):
    def test_missing_list_refuses(self):
        self.list.unlink()
        rc, err = self.run_script("text", stdin="hello\n")
        self.assertEqual(rc, 1)
        self.assertIn("not found", err)

    def test_comment_only_list_refuses(self):
        self.list.write_text("# only a comment\n\n")
        rc, err = self.run_script("text", stdin="hello\n")
        self.assertEqual(rc, 1)
        self.assertIn("empty", err)


class TreeAndRangeTests(Base):
    def test_tree_finds_the_identifier_and_passes_a_clean_tree(self):
        clean = self.commit("a.txt", "clean\n")
        self.assertEqual(self.run_script("tree", clean)[0], 0)
        dirty = self.commit("b.txt", "x " + WORD + " y\n")
        self.assertEqual(self.run_script("tree", dirty)[0], 1)

    def test_a_line_added_and_removed_later_is_caught(self):
        base, tip = self.added_then_removed()
        rc, err = self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n")
        self.assertEqual(rc, 1)
        self.assertIn("added by an outgoing commit", err)

    def test_an_unreadable_utf8_line_does_not_hide_the_lines_after_it(self):
        # macOS の awk は UTF-8 のロケールで読めないバイトに当たると止まる。その後ろの行も見ること
        base = self.commit("a.txt", "clean\n", "start")
        self.commit("a.txt", b"clean\n\xff\xfe broken\n" + WORD.encode() + b"\n", "add")
        tip = self.commit("a.txt", "clean\n", "remove")
        env = dict(self.env)
        env["LC_ALL"] = "en_US.UTF-8"
        rc, _ = self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n", env=env)
        self.assertEqual(rc, 1)


class FailureTests(Base):
    def test_a_failing_grep_refuses_instead_of_passing(self):
        base, tip = self.added_then_removed()
        # 検査語の一覧を読む grep（-f）だけ失敗させる。一覧の前処理（-v）と git grep は本物のまま
        env = self.fake("grep", 'for a in "$@"; do [ "$a" = "-f" ] && exit 2; done\nexec /usr/bin/grep "$@"')
        rc, err = self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n", env=env)
        self.assertEqual(rc, 1)
        self.assertIn("grep failed", err)

    def test_a_failing_awk_refuses_instead_of_passing(self):
        base, tip = self.added_then_removed()
        env = self.fake("awk", "exit 2")
        rc, err = self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base}\n", env=env)
        self.assertEqual(rc, 1)
        self.assertIn("awk failed", err)


class RemoteScopeTests(Base):
    def setUp(self):
        super().setUp()
        for name in ("origin", "other"):
            subprocess.run(["git", "init", "-q", "--bare", str(self.tmp / f"{name}.git")], check=True,
                           capture_output=True, env=self.env)
            self.git("remote", "add", name, str(self.tmp / f"{name}.git"))

    def test_a_new_ref_checks_commits_that_only_another_remote_has(self):
        _, tip = self.added_then_removed()
        # 別の remote にだけ載せる（この一時のリポジトリにはフックが無い）
        self.git("push", "-q", "other", "main")
        stdin = f"refs/heads/main {tip} refs/heads/main {ZERO}\n"
        rc, err = self.run_script("pre-push", "origin", stdin=stdin)
        self.assertEqual(rc, 1)
        self.assertIn("added by an outgoing commit", err)

    def test_a_push_to_a_url_checks_the_whole_history(self):
        _, tip = self.added_then_removed()
        self.git("push", "-q", "other", "main")
        stdin = f"refs/heads/main {tip} refs/heads/main {ZERO}\n"
        rc, _ = self.run_script("pre-push", str(self.tmp / "origin.git"), stdin=stdin)
        self.assertEqual(rc, 1)

    def test_commits_already_on_the_push_target_are_not_rechecked(self):
        _, tip = self.added_then_removed()
        self.git("push", "-q", "origin", "main")
        new = self.commit("b.txt", "more\n")
        stdin = f"refs/heads/topic {new} refs/heads/topic {ZERO}\n"
        rc, err = self.run_script("pre-push", "origin", stdin=stdin)
        self.assertEqual(rc, 0, err)


class HookTests(unittest.TestCase):
    def test_the_hook_passes_the_remote_name(self):
        self.assertIn('check-private-identifiers.sh" pre-push "$1"', HOOK.read_text())


if __name__ == "__main__":
    unittest.main()
