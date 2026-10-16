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


NO_SUCH_LOCALE = "xx_XX.UTF-8"
# (一覧に書く検査語, それに当たる文面)。文字としての扱いが要る書き方: 漢字を挟む「.」、U+3000 を含む括弧、全角文字の -i
CHARACTER_CASES = [
    ("山田.?太郎", "山田　太郎"),
    ("山田[ 　]?太郎", "山田　太郎"),
    ("ｙａｍａｄａ", "ＹＡＭＡＤＡ"),
]


class DualLocaleTests(Base):
    """照合は C ロケールと UTF-8 ロケールの両方で行う（不正なバイトと同じ行の識別子・文字としての検査語の両方を拾う）。"""

    def set_list(self, *patterns):
        self.list.write_text("\n".join(patterns) + "\n", encoding="utf-8")

    def push(self, tip, base=None, env=None, locale=None):
        e = dict(env or self.env)
        if locale:
            e["LC_ALL"] = locale
        return self.run_script("pre-push", stdin=f"refs/heads/main {tip} refs/heads/main {base or self.base}\n", env=e)

    def leak_then_remove(self, before, text=None, message="add"):
        """識別子を足すコミットと消すコミットを作る（先端のファイル全体・名前・メッセージはきれい）。先端を返す。"""
        self.round = getattr(self, "round", 0) + 1
        clean = f"clean {self.round}\n"                  # 繰り返しても毎回コミットが作れるように中身を変える
        self.base = self.commit("a.txt", clean, "start")
        self.commit("a.txt", clean.encode() + before + (text or WORD).encode() + b"\n", message)
        return self.commit("a.txt", clean, "remove")

    def test_identifier_on_the_same_line_after_invalid_bytes_stops_in_push(self):
        tip = self.leak_then_remove(b"\xff\xfe ")
        for locale in ("en_US.UTF-8", "C"):
            with self.subTest(locale=locale):
                rc, err = self.push(tip, locale=locale)
                self.assertEqual(rc, 1, err)
                self.assertIn("added by an outgoing commit", err)

    def test_identifier_on_the_next_line_after_invalid_bytes_stops_in_push(self):
        tip = self.leak_then_remove(b"before \xff\xfe after\n")
        self.assertEqual(self.push(tip, locale="en_US.UTF-8")[0], 1)

    def test_identifier_on_the_same_line_after_invalid_bytes_stops_in_text(self):
        for locale in ("en_US.UTF-8", "C"):
            with self.subTest(locale=locale):
                path = self.tmp / "raw.txt"
                path.write_bytes(b"\xff\xfe " + WORD.encode() + b"\n")
                env = dict(self.env, LC_ALL=locale)
                self.assertEqual(self.run_script("text", str(path), env=env)[0], 1)

    def test_identifier_in_a_commit_message_line_with_invalid_bytes_stops(self):
        self.base = self.commit("a.txt", "clean\n", "start")
        self.repo.joinpath("a.txt").write_text("clean\nmore\n")
        self.git("add", "a.txt")
        msg = self.tmp / "msg.bin"
        msg.write_bytes(b"change\n\n\xff\xfe " + WORD.encode() + b"\n")
        self.git("commit", "-q", "--cleanup=verbatim", "-F", str(msg))
        tip = self.git("rev-parse", "HEAD")
        rc, err = self.push(tip, locale="en_US.UTF-8")
        self.assertEqual(rc, 1, err)
        self.assertIn("commit messages", err)

    def test_character_patterns_stop_in_push_tree_and_text(self):
        # 利用者のロケールが C でも UTF-8 でも、文字として扱う検査語が当たること
        for locale in ("en_US.UTF-8", "C"):
            for pattern, text in CHARACTER_CASES:
                with self.subTest(locale=locale, pattern=pattern):
                    self.set_list(pattern)
                    env = dict(self.env, LC_ALL=locale)
                    tip = self.leak_then_remove(b"", text)
                    rc, err = self.push(tip, env=env)                  # パッチだけ（先端は消した後できれい）
                    self.assertEqual(rc, 1, err)
                    self.assertIn("added by an outgoing commit", err)
                    leaked = self.commit("b.txt", text + "\n")
                    rc, err = self.run_script("tree", leaked, env=env)
                    self.assertEqual(rc, 1, err)
                    self.assertIn("files of", err)
                    rc, err = self.run_script("text", stdin=text + "\n", env=env)
                    self.assertEqual(rc, 1, err)
                    self.assertIn("found in the text", err)
                    self.git("rm", "-q", "b.txt")
                    self.git("commit", "-q", "-m", "drop")

    def test_clean_inputs_pass_including_invalid_bytes_and_a_near_miss(self):
        self.set_list("山田.?太郎")
        path = self.tmp / "clean.txt"
        path.write_bytes(b"\xff " + "山田花子\n".encode())
        self.assertEqual(self.run_script("text", str(path))[0], 0)
        self.assertEqual(self.run_script("text", stdin="山田花子\n")[0], 0)
        self.base = self.commit("a.txt", "clean\n", "start")
        tip = self.commit("a.txt", b"\xff\xfe " + "山田花子\n".encode())
        rc, err = self.push(tip, locale="en_US.UTF-8")
        self.assertEqual(rc, 0, err)

    def test_failure_while_reading_the_list_stops(self):
        env = self.fake("grep", 'for a in "$@"; do [ "$a" = "-v" ] && { echo partial; exit 2; }; done\nexec /usr/bin/grep "$@"')
        rc, err = self.run_script("text", stdin="clean\n", env=env)
        self.assertNotEqual(rc, 0)
        self.assertIn("could not read the identifier list", err)

    def test_missing_utf8_locale_stops(self):
        tip = self.commit("a.txt", "clean\n")
        env = dict(self.env, STACKNEST_GUARD_UTF8_LOCALE=NO_SUCH_LOCALE)
        for args, stdin in ((("pre-push",), f"refs/heads/main {tip} refs/heads/main {ZERO}\n"),
                            (("tree", tip), ""), (("text",), "clean\n")):
            with self.subTest(mode=args[0]):
                rc, err = self.run_script(*args, stdin=stdin, env=env)
                self.assertEqual(rc, 1, err)
                self.assertIn("locale", err)

    def test_failing_iconv_stops(self):
        env = self.fake("iconv", "exit 1")
        rc, err = self.run_script("text", stdin="clean\n", env=env)
        self.assertNotEqual(rc, 0)

    def test_first_file_without_a_final_newline_does_not_join_the_next(self):
        self.set_list("^" + WORD)
        first, second = self.tmp / "first.txt", self.tmp / "second.txt"
        first.write_bytes(b"abc")
        second.write_bytes(WORD.encode() + b"\n")
        self.assertEqual(self.run_script("text", str(first), str(second))[0], 1)

    def test_a_missing_file_stops_text(self):
        rc, err = self.run_script("text", str(self.tmp / "nope.txt"))
        self.assertNotEqual(rc, 0)


class HookTests(unittest.TestCase):
    def test_the_hook_passes_the_remote_name(self):
        self.assertIn('check-private-identifiers.sh" pre-push "$1"', HOOK.read_text())


if __name__ == "__main__":
    unittest.main()
