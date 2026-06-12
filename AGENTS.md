# Agent Guide

This repository owns `xinit`, Laputa's pure-XSH init and service manager. Keep
the implementation small, explicit, and understandable as PID 1 code. The
integration repository lives at `~/d/laputa-systems/laputa`; package definitions
and installed service modules live at `~/d/laputa-systems/packages`.

## Architecture

`xinit.xsh` has two related jobs:

- PID 1 lifecycle from an inittab file.
- Service control for named XSH service modules.

The inittab path is the system boot spine. With no command arguments, `xinit`
reads `XSH_INIT_INITTAB` or `/etc/inittab`, runs `sysinit` entries
synchronously, starts process entries, supervises owned process groups, handles
restart/shutdown signals, and performs final halt, reboot, or poweroff.

The service path is the operational service manager. `xinit start SERVICE`,
`stop`, `restart`, `reload`, `status`, `logs`, `list`, `graph`, `check`, `boot`,
`supervise`, and `scan` operate on modules under `XINIT_SERVICE_DIR`, defaulting
to `/usr/lib/xinit/services`.

`supervise` and `scan` are one mechanism: the `ServiceUnit` scanner
(`scan_units`) that holds units and reconciles them with non-blocking backoff.
`supervise SERVICE` holds one unit; `scan [SERVICE|TARGET]` holds a whole
dependency tree. The scanner is the source of truth for its services and drains
a desired-state control inbox; `start`/`stop` post to that inbox when a live
scanner owns the run directory. A `readiness: "notify"` service is held in
`starting` until it writes its `NOTIFY_FD` byte (or `ready_timeout_ms` elapses).
See `docs/SUPERVISION.md` before changing the scanner, `reconcile_*`,
`read_status` liveness, the readiness state machine, or the inbox protocol.

The scanner depends on xsh primitives added for it: `time.millis`/`time.seconds`
(build a `Duration` from an `Int`), `unix.wait_pid1_event(timeout:)` (deadline
wait, `timeout` event kind), and `unix.spawn_process_group(..., notify: true)`
with `unix.notify_ready`/`unix.notify_close` (readiness fd). The sibling xsh
checkout must be rebuilt (`cargo build --bin xsh --bin xsht`) after pulling.

The two paths intentionally meet through ordinary commands. For example, the
baselayout inittab starts `/usr/lib/init/mdev.supervise`, and that script runs
`/usr/bin/xinit supervise mdevd`. There is no hidden IPC protocol between the
inittab engine and service engine.

## Service Model

Each service file exports one `service` record. The older top-level `services`
list format is not accepted for new work.

```xsh
export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv(/usr/bin/demo, ["demo", "--foreground"]),
  targets: ["boot"],
  dependencies: {need: ["net"], uses: ["logger"], after: ["firewall"]},
  restart: {mode: "on_failure", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
  logging: "append",
}
```

Use `uses`, not `use`, because `use` is an XSH keyword. Built-in facility names
are `logger`, `net`, `dns`, and `firewall`; other dependencies must resolve to
service files.

Service modules may also export lifecycle hooks:

```xsh
export proc start() [fs, process, env, error] -> Result[Unit]
export proc stop() [fs, process, env, time, error] -> Result[Unit]
export proc reload() [fs, process, env, error] -> Result[Unit]
export proc finish() [fs, process, env, error] -> Result[Unit]
export proc ready() [fs, process, env, time, error] -> Result[Bool]
export proc status() [fs, process, env, error] -> Result[Str]
```

Prefer a structured `command` for normal long-running daemons. Use custom hooks
only when the service has real lifecycle behavior that cannot be expressed as a
foreground process.

## Design Philosophy

`xinit` should be closer to a small, inspectable OpenRC-style service manager
than to a framework. Service files should make ordering and lifecycle facts
obvious at the module boundary. The intended mental model is:

- `need`: must be started first.
- `uses`: optional facility dependency, useful for logger, net, dns, firewall.
- `after`: ordering only.
- `before`: inverse ordering only.
- `ready()`: declares when dependents may proceed.
- `logging`: per-service built-in capture, default `append`, explicit `off`.

Borrow the good ideas from s6/skalibs: supervise foreground daemons, keep
process ownership explicit, use readiness contracts where ordering alone is not
enough, and treat log capture as part of service execution. Do not copy runit's
separate logging service layout.

`docs/SUPERVISION.md` is the standing proposal for unifying the inittab respawn
engine and the per-service supervisor onto one scanner model where the
supervisor — not a pidfile — is the source of truth. Read it before changing
`run_pid1`, `spawn_entries`, `supervise_service`, or the status/pid handling in
`read_status`/`stop_service`.

The CLI should stay boring and discoverable:

```text
xinit boot [TARGET]
xinit start SERVICE
xinit stop SERVICE
xinit restart SERVICE
xinit status SERVICE
xinit logs SERVICE
xinit list
xinit graph [SERVICE|TARGET]
xinit check [SERVICE|PATH]
```

## Logging

Built-in logging is intentionally simple. `logging: "append"` captures combined
stdout/stderr to `${XINIT_LOG_ROOT}/SERVICE/current`, with `XINIT_LOG_ROOT`
defaulting to `/var/log`. `logging: "off"` disables capture for that service.

Do not add a separate logging service dependency or a runit-style log directory
protocol. Future rotation or timestamping should extend the built-in log path
without making every service author wire logging by hand.

## PID 1 Rules

PID 1 code must be conservative:

- Avoid shell strings. Use structured argv.
- Keep shutdown paths simple and predictable.
- Preserve owned process-group tracking.
- Do not assume Linux-only behavior unless the call is already behind a Linux
  API or test dry-run path.
- Keep signal handling and child reaping easy to audit.
- Avoid global state that makes restart or test behavior order-dependent.

Tests may set `XINIT_TEST_ALLOW_NON_PID1=1`, `XSH_UNIX_DRY_RUN=1`, and
`XSH_LINUX_DRY_RUN=1`. Production PID 1 behavior must not depend on those
test-only paths.

## Package Integration

The package repository installs `xinit` as `/usr/bin/xinit`, `/usr/bin/init`,
and `/init`. Baselayout owns `/etc/inittab`, `/usr/lib/init/rc.boot`,
`/usr/lib/init/rc.shutdown`, `/usr/lib/init/mdev.supervise`, and the default
`mdevd` service module.

When the service schema changes, update all installed service modules in the
package repository in the same change. In particular, check:

- `packages/repo/baselayout/files/rootfs/usr/lib/xinit/services/`
- `packages/repo/dropbear/files/dropbear.xsh`
- `packages/repo/tailscale/files/tailscale.xsh`
- generated service text in package recipes such as `seatd`
- `packages/repo/xinit/files/xinit.xsh` if the package uses a snapshot

## Verification

Use the narrowest proof that exercises the changed behavior:

```sh
make verify
```

That runs type checks, formatting checks, lint, and the XSH test suite.

For service-module compatibility with the package repository:

```sh
../xsh/target/debug/xsh xinit.xsh -- check ../packages/repo/baselayout/files/rootfs/usr/lib/xinit/services/mdevd.xsh
../xsh/target/debug/xsh xinit.xsh -- check ../packages/repo/dropbear/files/dropbear.xsh
../xsh/target/debug/xsh xinit.xsh -- check ../packages/repo/tailscale/files/tailscale.xsh
```

For boot-level integration, use the Laputa repository's QEMU harness.

## Style

- Prefer direct records and helper procs over class-like abstractions.
- Keep comments focused on non-obvious PID 1 or service-manager behavior.
- Do not add dependencies.
- Preserve useful comments when refactoring.
- Do not run pre-commit hooks.
- Do not push.
