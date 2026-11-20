#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/scripts/tools.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_case () {
    emacs_build_root="$work/$1"
    source_dir="$emacs_build_root/source"
    mkdir -p "$emacs_build_root/patches/emacs" "$source_dir"
    git init --quiet "$source_dir"
    printf 'base\n' > "$source_dir/value.txt"
    cat > "$emacs_build_root/patches/emacs/0001.patch" <<'PATCH'
diff --git a/value.txt b/value.txt
--- a/value.txt
+++ b/value.txt
@@ -1 +1 @@
-base
+first
PATCH
    cat > "$emacs_build_root/patches/emacs/0002.patch" <<'PATCH'
diff --git a/value.txt b/value.txt
--- a/value.txt
+++ b/value.txt
@@ -1 +1 @@
-first
+second
PATCH
}

new_case ordered
printf '%s\n' '# Ordered selection' '' '0001.patch' '0002.patch' > "$emacs_build_root/series"
printf 'not a patch\n' > "$emacs_build_root/patches/emacs/0003.patch"
apply_patches "$source_dir" series
test "$(<"$source_dir/value.txt")" = second
echo 'PASS: series order and exclusion of unselected patches'

new_case failure
sed 's/^-base$/-absent/' "$emacs_build_root/patches/emacs/0001.patch" > "$emacs_build_root/broken"
mv "$emacs_build_root/broken" "$emacs_build_root/patches/emacs/0001.patch"
cat > "$emacs_build_root/patches/emacs/0002.patch" <<'PATCH'
diff --git a/later.txt b/later.txt
new file mode 100644
--- /dev/null
+++ b/later.txt
@@ -0,0 +1 @@
+must not be applied after failure
PATCH
if apply_patches "$source_dir"; then
    echo 'FAIL: a conflicting patch was reported as successful' >&2
    exit 1
fi
test "$(<"$source_dir/value.txt")" = base
test ! -e "$source_dir/later.txt"
echo 'PASS: failure stops before later patches'

new_case missing
printf 'absent.patch\n' > "$emacs_build_root/series"
if apply_patches "$source_dir" series; then
    echo 'FAIL: a missing selected patch was ignored' >&2
    exit 1
fi
echo 'PASS: a missing selected patch fails'

new_case missing-series
if apply_patches "$source_dir" absent-series; then
    echo 'FAIL: a missing series was ignored' >&2
    exit 1
fi
echo 'PASS: a missing series fails'

new_case defaults
apply_patches "$source_dir"
test "$(<"$source_dir/value.txt")" = second
echo 'PASS: default filename ordering'

new_case crlf
for patch in "$emacs_build_root/patches/emacs/"*.patch; do
    awk '{printf "%s\r\n", $0}' "$patch" > "$emacs_build_root/crlf"
    mv "$emacs_build_root/crlf" "$patch"
done
printf '%s\r\n' '0001.patch' '0002.patch' > "$emacs_build_root/series"
apply_patches "$source_dir" series
test "$(<"$source_dir/value.txt")" = second
echo 'PASS: CRLF series and patch normalization'

producer="$work/producer"
git init --quiet -b main "$producer"
git -C "$producer" config core.autocrlf false
printf 'first \\\nsecond\n' > "$producer/configure.ac"
git -C "$producer" add configure.ac
git -C "$producer" -c user.name='Build fixture' -c user.email='build@example.invalid' \
    commit --quiet -m 'Create clone fixture'
printf '[core]\n\tautocrlf = true\n' > "$work/user.gitconfig"
(
    export GIT_CONFIG_GLOBAL="$work/user.gitconfig"
    clone_repo main "$producer" "$work/cloned"
    test "$(git -C "$work/cloned" config --local --get core.autocrlf)" = false
    test "$(git -C "$work/cloned" config --local --get core.eol)" = lf
)
# clone_repo removes generated configure, not its Autoconf source.
cmp "$producer/configure.ac" "$work/cloned/configure.ac"
echo 'PASS: fresh source clones retain LF despite a global CRLF preference'

new_case locked-series
printf '0001.patch\n' > "$emacs_build_root/series"
powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$root/scripts/tests/test-patches-locked-series.ps1")" \
    -Fixture "$(cygpath -w "$emacs_build_root")" \
    -Tools "$(cygpath -w "$root/scripts/tools.sh")" \
    -Bash "$(cygpath -w "$(command -v bash)")"
test "$(<"$source_dir/value.txt")" = base
echo 'PASS: locked series applies no patches'
cli="$work/cli"
mkdir -p "$cli/scripts" "$cli/patches/emacs" "$cli/bin"
cp "$root/emacs-build.sh" "$cli/"
for helper in tools pdf-tools aspell hunspell msys2_extra gnutls; do
    cp "$root/scripts/$helper.sh" "$cli/scripts/"
done
cp "$work/failure/patches/emacs/"*.patch "$cli/patches/emacs/"
printf '%s\n' '0001.patch' '0002.patch' > "$cli/series"
# Keep the fixture independent of the installed MSYS2 package set.
printf '#!/usr/bin/env bash\nexit 0\n' > "$cli/bin/pacman"
chmod +x "$cli/bin/pacman"
if (cd "$cli" && PATH="$cli/bin:$PATH" MSYSTEM=UCRT64 \
        MINGW_PREFIX=/ucrt64 MINGW_PACKAGE_PREFIX=mingw-w64-ucrt-x86_64 \
        bash ./emacs-build.sh --clone --configure --repo "$producer" --branch main \
        --patch-series series > "$cli/stdout" 2> "$cli/stderr"); then
    echo 'FAIL: the build command succeeded after Git rejected a patch' >&2
    exit 1
fi
grep -Fq 'error: ' "$cli/stderr"
grep -Fq "Patch failed; build preparation stopped: $cli/patches/emacs/0001.patch" "$cli/stderr"
grep -Fq 'Action action0_clone failed.' "$cli/stderr"
if grep -Fq 'Preparing build directory' "$cli/stdout" || test -e "$cli/git/main/later.txt"; then
    echo 'FAIL: the build command continued after a patch failure' >&2
    exit 1
fi
echo 'PASS: the build command reports patch failure on stderr and exits before configuration'
echo '9 build-preparation checks passed'
