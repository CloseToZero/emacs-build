<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Windows reader retirement and process completion

Patch `0039-Retire-W32-readers-before-slot-reuse.patch` keeps a Windows reader's context,
synchronization objects and detached descriptor alive until the reader actually exits. Closing a
thread handle does not terminate its thread. A descendant or a module retaining a pipe writer can
keep the old read outstanding after the Emacs process object has been deleted.

Retirement is independent of read status, so late I/O cannot turn a retired reader into a new
owner. The main thread transfers descriptor closure before requesting retirement and fulfils that
obligation after a zero-time exit check. The reader no longer closes a descriptor through a timed
flag handshake. Outstanding readers reserve their slots without an unbounded main-thread join.
Socket shutdown and serial cancellation precede handle reclamation; accept/connect waits observe
retirement even if a late result changes read status.

The patch also repairs a downstream 0035 boundary: status notification and redisplay can invoke
callbacks that consume data, delete processes or allocate replacements. Poll again after those
callbacks rather than using the earlier read/write readiness sets against current owners. Keep
0035's prompt completion notifications and Windows wait wakeups; do not restore the old idle
sentinel delay or add arbitrary polling/retry limits.

## Run the isolated checks

Use the dedicated UCRT64 compiler and a module-capable Windows Emacs. For the build executable:

```powershell
./scripts/tests/test-w32-pipes.ps1 `
  -Emacs ./build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe `
  -ModuleInclude ./build/emacs-31-mingw-w64-ucrt-x86_64/src
```

For a full package extraction, the default header location is its `include/` directory:

```powershell
./scripts/tests/test-w32-pipes.ps1 -Emacs C:/isolated-package/bin/emacs.exe -Standalone
```

The runner compiles an independent test child and a small module using only the public Emacs
module channel API and CRT I/O. It launches a new batch Emacs with disposable home, XDG state
and an explicit init directory, clearing inherited server settings. `-Standalone` restricts runtime
PATH to the package and Windows directories, without the build toolchain. Its external watchdog can
terminate only the process it created. It never attaches to, restarts or replaces an existing
editor. Logs remain in the reported temporary directory; `-WorkDirectory` chooses a retained run.

The cases cover:

- An old writer retained across deletion, followed by a late byte after a replacement reader is
  created. The late completion must not appear in the replacement or stall its main loop.
- A completion callback that recursively consumes ready data, deletes its owner, creates a
  replacement, and receives subsequent data through that replacement.
- Sixty-four short commands with separate stderr, complete final output and sentinel delivery
  without keyboard input, preserving the completion behavior needed by process clients.
- More sequential reader generations than the existing child-slot table can hold, with a
  steady-state kernel-handle count comparison rather than allocation success alone.
- A missing executable followed by successful pipe I/O.
- Repeated real loopback accept/connect, output and teardown.
- One MiB of stdout plus final stderr, checking completeness rather than a tiny-output fast path.

The retained-writer case reproduces a native stall in the preceding downstream release. A focused
negative control uses `-Selector '^emacsbuild-pipe-retired-reader-' -TimeoutSeconds 12`. Its timeout
is a test-process watchdog, not a new product timeout or a promise about every scheduling race.
The callback case is a behavioral guard, not a separately established failing baseline.

## Boundaries

The code review also covers startup cleanup, serial ownership and late cancellation, but these
checks do not inject event/thread-allocation failures or exercise physical serial hardware.
They do not measure remote Git server or authentication latency, and do not guarantee termination
of descendants that retain a writer indefinitely. Such outstanding I/O keeps its resources until
completion instead of lending them to a replacement reader. Existing slot/descriptor exhaustion
remains an operational failure, not permission to reuse live ownership.

Run the actual packaged executable too. Earlier check results, a successful build, or a source
revision alone do not certify the new executable, portable dump or selected patch payloads.
