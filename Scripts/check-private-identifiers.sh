#!/usr/bin/env bash
# 公開の場（この repo・上流 Washi への push と Issue/PR）に個人識別子を出さないための検査。
# 2026-10-01: 実名がコードのコメントに入ったまま main に push されていた事故を受けて機械化した。
#
# 検査する語の一覧はリポジトリの外に置く（中身そのものが識別子なので、ここには書かない）:
#   ${STACKNEST_PRIVATE_IDENTIFIERS_FILE:-$HOME/.config/stacknest/private-identifiers}
#   1 行 1 つの拡張正規表現・大文字小文字を区別しない・# で始まる行と空行は無視。
# 一覧が無い・空のときは失敗する（見落とすより止まる方を選ぶ）。
#
# 使い方:
#   check-private-identifiers.sh pre-push [remote] pre-push フックの標準入力（ref の組）を読み、
#                                                  push する先端のファイル全体・新しいコミットで
#                                                  足された行とファイル名・メッセージ・作成者を検査する
#   check-private-identifiers.sh tree <rev>        <rev> のファイル全体を検査する
#   check-private-identifiers.sh text [file...]    ファイル（無ければ標準入力）の文面を検査する
# 見つかったら該当箇所を出して終了コード 1。見つからなければ 0。
set -euo pipefail

LIST="${STACKNEST_PRIVATE_IDENTIFIERS_FILE:-$HOME/.config/stacknest/private-identifiers}"
ZERO="0000000000000000000000000000000000000000"

fail() { echo "private-identifiers: $*" >&2; exit 1; }

[ -r "$LIST" ] || fail "identifier list not found: $LIST (refusing; create it before pushing or posting)"
PATTERNS="$(mktemp -t private-identifiers)"
trap 'rm -f "$PATTERNS"' EXIT
rc=0
grep -v -E '^[[:space:]]*(#|$)' "$LIST" > "$PATTERNS" || rc=$?
[ "$rc" -le 1 ] || fail "could not read the identifier list: $LIST (grep exit $rc; refusing)"   # 1 は「採る行が無い」だけ
[ -s "$PATTERNS" ] || fail "identifier list is empty: $LIST (refusing)"

# 検査語の照合（grep・git grep）は C ロケールと UTF-8 のロケールの両方で行い、どちらかで当たれば当たりとする。
#   - C ロケール: UTF-8 として読めないバイトを含む行も、バイトのまま照合できる（UTF-8 の grep はその行を黙って飛ばす）。
#   - UTF-8 のロケール: 「.」や [ ] の中の漢字・全角の空白、全角文字の大文字小文字の無視など、文字として扱う書き方の検査語が
#     当たる（C ではバイト単位になり当たらない）。
# どちらかの実行が失敗（終了コード 0・1 以外）したら止まる。UTF-8 のロケールが無いときも止まる（C だけで続けない）。
# 行を取り出す awk は C ロケールで動かす（UTF-8 だと、不正なバイトの行で終了コード 2 になる。その失敗は呼び出し側が止める）。
# STACKNEST_GUARD_UTF8_LOCALE は試験用（ロケールが無いときの停止を試すために別の名前を渡す）。名前の指定先が UTF-8 でなければ止まる。
UTF8_LOCALE="${STACKNEST_GUARD_UTF8_LOCALE:-en_US.UTF-8}"
available="$(locale -a)" || fail "could not list the locales (locale -a failed); refusing"
case "
$available
" in
*"
$UTF8_LOCALE
"*) ;;
*) fail "the UTF-8 locale $UTF8_LOCALE is not installed (refusing; matching would be bytes-only)" ;;
esac
[ "$(LC_ALL=$UTF8_LOCALE locale charmap)" = "UTF-8" ] || fail "locale $UTF8_LOCALE is not a UTF-8 locale (refusing)"

# 標準入力の文面を 2 つのロケールで grep する。引数は grep の引数。0 = 当たり（行を標準出力へ）、1 = 一致なし、2 = 失敗
both_grep() {
    local input clean out_c out_u rc_c=0 rc_u=0
    input="$(cat)" || return 2
    out_c="$(printf '%s\n' "$input" | LC_ALL=C grep "$@")" || rc_c=$?
    # UTF-8 の grep は、不正なバイトを含む行を黙って飛ばす。UTF-8 の実行には、不正な並びを落とした写し（改行は残るので
    # 行番号は同じ）を渡す。先に変数へ取る（iconv の失敗をパイプの中で隠さない）。不正なバイトの行の中の識別子は C の実行が拾う
    clean="$(printf '%s\n' "$input" | iconv -f UTF-8 -t UTF-8 -c)" || { echo "private-identifiers: iconv failed" >&2; return 2; }
    out_u="$(printf '%s\n' "$clean" | LC_ALL="$UTF8_LOCALE" grep "$@")" || rc_u=$?
    { [ "$rc_c" -le 1 ] && [ "$rc_u" -le 1 ]; } || return 2
    [ -n "$out_c$out_u" ] || return 1
    { [ -z "$out_c" ] || printf '%s\n' "$out_c"; [ -z "$out_u" ] || printf '%s\n' "$out_u"; } | LC_ALL=C sort -u || return 2
    return 0
}

# git grep を 2 つのロケールで行う（引数は git grep の引数）。同じ約束: 0 = 当たり、1 = 一致なし、2 = 失敗
both_git_grep() {
    local out_c out_u rc_c=0 rc_u=0
    out_c="$(LC_ALL=C git "$@")" || rc_c=$?
    out_u="$(LC_ALL="$UTF8_LOCALE" git "$@")" || rc_u=$?
    { [ "$rc_c" -le 1 ] && [ "$rc_u" -le 1 ]; } || return 2
    [ -n "$out_c$out_u" ] || return 1
    { [ -z "$out_c" ] || printf '%s\n' "$out_c"; [ -z "$out_u" ] || printf '%s\n' "$out_u"; } | LC_ALL=C sort -u || return 2
    return 0
}

found=0

# <rev> のファイル全体（バイナリは除く）
check_tree() {
    # ファイル全体は 2 つのロケールで照合するだけで、不正なバイトの行の写し（both_grep の iconv）は使わない。その行の中の識別子は、
    # 押す先に無い新しい内容ならどれかのコミットが足した行なので check_patches が見る
    local rev="$1" rc=0 hits
    hits="$(both_git_grep grep -I -n -i -E -f "$PATTERNS" "$rev" -- .)" || rc=$?
    case "$rc" in
    0) echo "$hits" >&2; echo "private-identifiers: personal identifier found in the files of $rev" >&2; found=1 ;;
    1) ;;                                              # 一致なし
    *) fail "git grep failed on $rev (exit $rc)" ;;    # 一致なしと取り違えない
    esac
}

# 範囲内の各コミットで足された行（途中のコミットで入れて後で消した識別子も公開されるため。
# 消した行は見ない — 見ると、識別子を消すコミットそのものが止まる）。マージのコミットは第 1 親との
# 差分として見る（衝突の解消の中で入った行も拾う）
check_patches() {
    local patch added hits rc=0
    patch="$(git log -p --diff-merges=first-parent --no-color --no-ext-diff --format='commit %h' "$@")" \
        || fail "git log -p failed: $*"
    # 足された行だけを、行頭の "+" を外して照合する（^ や $ で固定した検査語も当たるように）。
    # 見出しの "+++ b/…" と、"++ " で始まる足した行（パッチでは "+++ " になる）を取り違えないよう、
    # "@@" の区切りの中だけを見る。awk は C ロケールで動かす（UTF-8 だと不正なバイトの行で終了コード 2 になり、
    # その push を止めてしまう）。awk と grep を 1 本のパイプにすると awk の失敗が grep の「一致なし(1)」に隠れるので、段を分けて状態を見る
    added="$(printf '%s\n' "$patch" \
        | LC_ALL=C awk '/^diff --git /{h=0; next} /^@@/{h=1; next} h && /^\+/{print substr($0, 2)}')" \
        || fail "awk failed on the outgoing patches"
    hits="$(printf '%s\n' "$added" | both_grep -i -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the added lines (exit $rc)"   # 一致なし(1)と取り違えない
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier added by an outgoing commit (even if removed later)" >&2
        found=1
    fi
}

# 範囲内の各コミットで足した・名前を変えた・写したファイルの名前（中身の無いファイルやバイナリは
# パッチの見出しに名前が出ないので、名前の一覧として別に見る。-z で非 ASCII の名前の引用を避ける）
check_paths() {
    local names hits rc=0
    names="$(git log --diff-merges=first-parent --format= --name-only -z --diff-filter=ACR "$@" | LC_ALL=C tr '\0' '\n')" \
        || fail "git log --name-only failed: $*"
    hits="$(printf '%s\n' "$names" | both_grep -i -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the file names (exit $rc)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier in a file name added by an outgoing commit" >&2
        found=1
    fi
}

# 範囲内の各コミットのメッセージと作成者・コミッタ
check_commits() {
    local log hits rc=0
    # 名前・メール・本文の各行をそのまま 1 行ずつ照合する（^ や $ で固定した検査語も当たるように）
    log="$(git log --format='%an%n%ae%n%cn%n%ce%n%B' "$@")" || fail "git log failed: $*"
    hits="$(printf '%s\n' "$log" | both_grep -n -i -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the commit messages (exit $rc)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier found in commit messages or authors" >&2
        found=1
    fi
}

case "${1:-}" in
pre-push)
    # 省略可の第 2 引数: push 先の remote の名前（pre-push フックの $1）。新しい ref では、その remote の追跡 ref に
    # 無いコミットを新しいものとして見る（ほかの remote にあるだけのコミットは、この push で初めて公開されうる）。
    remote="${2:-}"
    while read -r local_ref local_sha remote_ref remote_sha; do
        [ "$local_sha" = "$ZERO" ] && continue          # ref の削除は検査しない
        check_tree "$local_sha"
        if [ "$remote_sha" = "$ZERO" ]; then
            if [ -z "$remote" ]; then set -- "$local_sha" --not --remotes
            elif git remote | grep -Fxq -- "$remote"; then set -- "$local_sha" --not "--remotes=$remote"
            else set -- "$local_sha"; fi                  # URL への push: 追跡 ref が無いので履歴をすべて見る
        else
            set -- "$remote_sha..$local_sha"
        fi
        check_commits "$@"
        check_patches "$@"
        check_paths "$@"
    done
    ;;
tree)
    [ -n "${2:-}" ] || fail "usage: $0 tree <rev>"
    check_tree "$2"
    ;;
text)
    shift
    rc=0
    # 先に全部を読む（cat の失敗をパイプの中で「一致なし」に埋もれさせない）
    if [ "$#" -eq 0 ]; then text="$(cat)" || fail "could not read the text (stdin)"
    else
        # ファイルごとに読み、最後に改行を足す（末尾の改行の無いファイルの最後の行が次のファイルの先頭行と繋がらないように）
        text="$(for f in "$@"; do cat -- "$f" || exit 1; printf '\n'; done)" || fail "could not read the text"
    fi
    hits="$(printf '%s\n' "$text" | both_grep -n -i -E -f "$PATTERNS")" || rc=$?
    case "$rc" in
    0) echo "$hits" >&2; echo "private-identifiers: personal identifier found in the text" >&2; found=1 ;;
    1) ;;
    *) fail "could not read the text (grep exit $rc)" ;;
    esac
    ;;
*)
    fail "usage: $0 pre-push | tree <rev> | text [file...]"
    ;;
esac

if [ "$found" -ne 0 ]; then
    echo "private-identifiers: refused. Remove the identifiers above and retry." >&2
    exit 1
fi
exit 0
