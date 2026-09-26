# opencode-termux

Run [opencode](https://github.com/anomalyco/opencode) and Bun-compiled binaries,
**natively on Termux**.

Works on **Android 10/11** (the versions where Bun binaries fail outright) and
is inert on Android 12+. Requires Termux's **glibc** packages.

## Why is this needed?

Bun-compiled binaries (opencode and most modern CLIs built with
`bun build --compile`) are plain glibc ELFs that hit **three unrelated walls**
on Android:

| # | Wall | Symptom |
|---|------|---------|
| 1 | The ELF interpreter `/lib/ld-linux-aarch64.so.1` does not exist on Android | `cannot execute: required file not found` |
| 2 | Termux's app session injects a **bionic** `LD_PRELOAD` shim globally; the glibc loader cannot resolve its dependencies | `invalid ELF header` — every glibc binary fails at startup |
| 3 | Android 10/11 seccomp **traps** `statx` and 10 other "modern" syscalls (`pidfd_open`, `clone3`, `io_uring_*`, `rseq`, `openat2`, `faccessat2`, ...). Bun calls `statx` via an **inline `svc`** that bypasses libc | `Bad system call` (exit 159) at startup |

Wall #3 is the killer: even a correctly patched glibc cannot help, because Bun
never goes through glibc for `statx`.

## The solution

A tiny launcher script + one ~4 KB LD_PRELOAD shim:

- the **launcher** clears the injected `LD_PRELOAD` and starts the binary through Termux's glibc loader (`ld.so`).
- the **shim** installs a `SIGSYS` handler: seccomp's `SECCOMP_RET_TRAP` action
  delivers a trapped syscall to userspace as a signal; the handler emulates
  `statx` with `fstatat` and reports every other trapped syscall as `-ENOSYS`,
  the standard "kernel does not provide this syscall" answer, so callers fall
  back to older syscalls;
- the shim is built **without `DT_NEEDED`** and references `__errno_location`
  weakly, so it also preloads harmlessly into the bionic children opencode
  spawns (`git`, `sh`, ...).

**Performance:** only 2 syscalls pay a ~2 µs tax per call; everything else runs
at full native speed — about **110× faster than proot** on filesystem syscalls.
See [docs/performance.md](docs/performance.md).

## Requirements

- Termux (aarch64) — Android 10/11 is the primary target; Android 12+ works too
  (the shim simply never fires)
- glibc packages:

  ```
  pkg install glibc-repo
  pkg install glibc glibc-runner
  ```

- `clang` (to build the shim) and `curl`:

  ```
  pkg install clang curl
  ```

## Install

One line, no clone needed:

```
curl -fsSL https://raw.githubusercontent.com/HanSoBored/opencode-termux/main/install.sh | bash
```

Or, if you prefer to read the installer before running it:

```
git clone https://github.com/HanSoBored/opencode-termux.git
cd opencode-termux
./install.sh
```

`install.sh` will:

1. resolve and download the latest `opencode-linux-arm64.tar.gz` release,
2. build the seccomp shim,
3. install everything under `~/.opencode/`:

   ```
   ~/.opencode/bin/opencode          # launcher (this is what you run)
   ~/.opencode/bin/opencode-bin      # the unpatched opencode binary
   ~/.opencode/lib/libseccomp-shim.so
   ```

When run through `curl | bash` there is no checkout, so the script fetches
just the two files it needs (`src/libseccomp-shim.c`, `src/opencode`) from
`raw.githubusercontent.com` instead of cloning the repo.

## Usage

```
opencode --version
opencode            # TUI
opencode run "..."  # headless
```

Make sure `~/.opencode/bin` is in `PATH` — if not:

```
echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> ~/.zshrc
```

## Why not proot?

Proot intercepts **every** syscall with ptrace and translates paths. Measured
on the same device, `fstatat` went from **2.75 µs → 304 µs (110×)** under
proot. This solution intercepts nothing except the 2 syscalls Android blocks,
at ~2 µs each.

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) — the interception mechanics, in depth
- [docs/performance.md](docs/performance.md) — measurements: native vs shim vs proot
- [docs/troubleshooting.md](docs/troubleshooting.md) — problems and fixes

## Tests

```
./tests/run-tests.sh
```

Builds the shim, then verifies an inline `statx` call is SIGSYS-killed without
the shim and succeeds with it.

## License

MIT
