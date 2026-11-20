# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
"""Verify an owned relocated extraction, with Homebrew and build trees denied."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

from build import ROOT, WORK, COMPILE, SOURCE, PRODUCT, run, digest
from bundle import APP, audit, product_identity


def checked(args, env, state, label, timeout=120):
    """An external watchdog kills only the process group created for this test."""
    with (state / f"{label}.stdout.log").open("w") as out, (state / f"{label}.stderr.log").open("w") as err:
        process = subprocess.Popen(list(map(str, args)), env=env, stdout=out, stderr=err,
                                   cwd=state, start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError(f"{label} timed out; see {state}")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    if result:
        raise RuntimeError(f"{label} exited {result}; see {state / (label + '.stderr.log')}")


def verify_client(app, sandbox, env, state, init):
    """Launch the native client against an owned, uniquely named GUI server."""
    client = app.parent / "Emacs Client.app"
    audit(client)
    with tempfile.TemporaryDirectory(prefix="ctz-emacs-socket-", dir="/tmp") as directory:
        socket = Path(directory) / "owned"
        expression = '(progn (require (quote server)) (setq server-name "owned" server-socket-dir ' + json.dumps(directory + "/") + ') (server-start))'
        with (state / "client-server.stdout.log").open("w") as out, (state / "client-server.stderr.log").open("w") as err:
            process = subprocess.Popen(list(map(str, [*sandbox, app / "Contents/MacOS/Emacs", "-Q", "--init-directory", init, "--eval", expression])),
                                       env=env, stdout=out, stderr=err, start_new_session=True)
            try:
                deadline = time.monotonic() + 20
                while not socket.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError(f"Owned client-test server did not start; see {state}")
                    time.sleep(0.05)
                query = [*sandbox, app / "Contents/MacOS/bin/emacsclient", "-s", socket, "--eval", "(length (frame-list))"]
                before = int(subprocess.check_output(list(map(str, query)), env=env, timeout=10, text=True))
                client_env = {**env, "EMACS_SOCKET_NAME": str(socket)}
                checked([*sandbox, client / "Contents/MacOS/EmacsClient"], client_env, state, "client-launch", timeout=20)
                after = int(subprocess.check_output(list(map(str, query)), env=env, timeout=10, text=True))
                if after <= before:
                    raise RuntimeError("Native client did not create a frame in the owned server")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


def verify():
    identity = product_identity()
    audit(APP)
    base = WORK / "verification"
    base.mkdir(exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix="relocated space-", dir=base)).resolve()
    (WORK / "latest-verification-path.txt").write_text(str(state) + "\n")
    # Verify a ZIP round trip, not just a copy of the pre-packaging directory.
    archive = state / "round-trip.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", PRODUCT, archive])
    extract = state / "extracted"
    run(["/usr/bin/ditto", "-x", "-k", archive, extract])
    app = extract / PRODUCT.name / "Emacs.app"
    if product_identity(extract / PRODUCT.name) != identity:
        raise RuntimeError("ZIP round trip changed the product, modes or symlinks")
    audit(app)
    audit(app.parent / "Emacs Client.app")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.parent / "Emacs Client.app"])
    profile = state / "no-homebrew.sb"
    blocked = ["/opt/homebrew", "/usr/local/Cellar", str(SOURCE), str(COMPILE), str(PRODUCT)]
    profile.write_text('(version 1)\n(allow default)\n' + ''.join(
        f'(deny file-read* (subpath {json.dumps(p)}))\n' for p in blocked))
    home = state / "home"
    temp = state / "tmp"
    init = state / "init"
    for path in (home, temp, init):
        path.mkdir()
    env = {"HOME": str(home), "TMPDIR": str(temp) + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "LC_ALL": "en_US.UTF-8", "TEST_APP_ROOT": str(app), "TEST_STATE": str(state),
           "REDISPLAY_TEST_STATE": str(state),
           "REDISPLAY_TEST_SELECTOR": "^\\(redisplay-tests-\\|macos-smoke-gui-\\)",
           "DYLD_PRINT_LIBRARIES": "1"}
    probe = SOURCE / "COPYING"
    denied = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), "/bin/cat", str(probe)],
                            env=env, capture_output=True)
    if denied.returncode == 0 or b"Operation not permitted" not in denied.stderr:
        raise RuntimeError("Sandbox denial was not enforced")
    c_source = state / "module-probe.c"
    c_source.write_text('''#include <emacs-module.h>
int plugin_is_GPL_compatible;
static emacs_value answer(emacs_env *env, ptrdiff_t n, emacs_value *args, void *data) {
  return env->make_integer(env, 42);
}
int emacs_module_init(struct emacs_runtime *runtime) {
  emacs_env *env = runtime->get_environment(runtime);
  emacs_value args[] = {env->intern(env, "ctz-macos-module-probe"),
    env->make_function(env, 0, 0, answer, "Isolated module probe.", 0)};
  env->funcall(env, env->intern(env, "fset"), 2, args);
  return 0;
}
''')
    run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-I" + str(COMPILE / "src"),
         c_source, "-o", state / "module-probe.dylib"])
    for name in ("black.webp", "blank-100x200.png"):
        shutil.copy2(SOURCE / "test/data/image" / name, state / name)
    emacs = app / "Contents/MacOS/Emacs"
    sandbox = ["/usr/bin/sandbox-exec", "-f", profile]
    smoke = ROOT / "scripts/macos/smoke.el"
    batch_selector = "^macos-smoke-\\(features\\|runtime-paths\\|aot\\|sqlite-and-xml\\|module\\|process\\|jit\\)$"
    checked([*sandbox, emacs, "--batch", "-q", "--init-directory", init, "-l", smoke,
             "--eval", f"(ert-run-tests-batch-and-exit {json.dumps(batch_selector)})"], env, state, "batch")
    quick_selector = "^macos-smoke-\\(features\\|runtime-paths\\|aot\\)$"
    checked([*sandbox, emacs, "--batch", "-Q", "--init-directory", init, "-l", smoke,
             "--eval", f"(ert-run-tests-batch-and-exit {json.dumps(quick_selector)})"], env, state, "quick-aot")
    checked([*sandbox, emacs, "-q", "--init-directory", init, "-l", smoke,
             "-l", ROOT / "scripts/tests/redisplay-tests.el"], env, state, "graphical", timeout=180)
    progress = (state / "progress.log").read_text()
    if "post-redisplay timer serviced" not in progress:
        raise RuntimeError("Graphical tests did not return to the event loop")
    messages = (state / "ert.log").read_text()
    if "11 results as expected" not in messages or "0 unexpected" not in messages:
        raise RuntimeError("Graphical ERT suite did not complete all 11 expected tests")
    verify_client(app, sandbox, env, state, init)
    # Actual verification of a TLS connection using system trust, no Cellar CA.
    tls = '(progn (require (quote url)) (require (quote gnutls)) (let ((url-request-timeout 30) (gnutls-verify-error t)) (with-current-buffer (or (url-retrieve-synchronously "https://elpa.gnu.org/" t t 30) (error "No HTTPS response")) (goto-char (point-min)) (unless (looking-at "HTTP/[0-9.]+ 200") (error "Unexpected HTTPS response")))))'
    checked([*sandbox, emacs, "--batch", "-Q", "--init-directory", init, "--eval", tls], env, state, "tls", timeout=45)
    logs = "".join(p.read_text(errors="replace") for p in state.glob("*.stderr.log"))
    if any("/opt/homebrew/" in line for line in logs.splitlines() if line.startswith("dyld[") and "/opt/homebrew/" in line):
        raise RuntimeError("A Homebrew image was loaded")
    if identity != product_identity():
        raise RuntimeError("Product changed during verification")
    result = {"success": True, "identity": identity, "state": str(state), "archive_sha256": digest(archive),
              "batch_erts": 7, "quick_aot_erts": 3, "graphical_erts": 11,
              "runtime": json.loads((state / "runtime.json").read_text()),
              "post_redisplay_timer": True, "https_system_trust": True, "native_client_launch": True,
              "sandbox_denied": blocked, "zip_round_trip": True,
              "signing": "ad-hoc, not notarized"}
    (WORK / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Relocated verification passed: {state}")
