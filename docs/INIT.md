# XSH Init

`xinit` is a pure XSH init and service supervisor script. It is the process
that should run as PID 1, usually as `/init` or `/usr/bin/xinit`, after
installation with an `xsh` interpreter shebang. Inittab commands, boot hooks,
shutdown hooks, and service definition modules are ordinary XSH or executable
commands.

`xsh --pid1` is not supported. PID 1 mechanics live in this `xinit.xsh` script
and the XSH `unix` and `linux` module APIs it calls.

## Invocation

```sh
xinit
xinit /etc/inittab
xinit boot [TARGET]
xinit scan [SERVICE|TARGET]
xinit start SERVICE
xinit restart SERVICE
xinit reload SERVICE
xinit supervise SERVICE
xinit status SERVICE
xinit logs SERVICE
xinit stop SERVICE
xinit list
xinit graph [SERVICE|TARGET]
xinit check [SERVICE|PATH]
```

With no argument, `xinit` reads `XSH_INIT_INITTAB` or `/etc/inittab`. PID 1
mode requires `getpid() == 1`; tests may set `XINIT_TEST_ALLOW_NON_PID1=1`.

Control commands use these paths by default:

- `XINIT_SERVICE_DIR`, default `/usr/lib/xinit/services`.
- `XINIT_RUN_DIR`, default `/run/xinit`.
- `XINIT_LOG_ROOT`, default `/var/log`.

`XINIT_LIB` is ignored for compatibility with older environments.

## Inittab

Each non-empty line is:

```text
id:runlevels:action:command
```

`runlevels` is parsed for compatibility but is not used. `command` is split
with XSH argv parsing, so quotes and escaped spaces work.

Supported actions:

- `sysinit`: run synchronously before services.
- `wait`: run synchronously after `sysinit`.
- `once`: start once and do not restart.
- `respawn`: supervise with launch delay and optional test launch limit.
- `poweroff`: start once; when it exits, stop owned process groups and power off.
- `restart`: exec on restart lifecycle.
- `shutdown`: run synchronously during shutdown after owned process groups stop.

Lifecycle signals:

- `SIGHUP`: restart.
- `SIGUSR1`: halt.
- `SIGUSR2`: poweroff.
- `SIGTERM`: reboot.
- `SIGINT`: poweroff.

Child exits are drained before lifecycle signals are processed. On Linux,
`xinit` enables child subreaper mode where available.

## Minimal Inittab

```text
::sysinit:/usr/lib/init/rc.boot
::restart:/usr/bin/xinit /etc/inittab
::shutdown:/usr/lib/init/rc.shutdown
ttyAMA0::poweroff:/bin/xshi --no-config
tty1::respawn:/bin/getty 38400 tty1
```

## Minimal Hooks

- `docs/minimal-rc.boot.xsh`
- `docs/minimal-rc.shutdown.xsh`

## Services

Service files live under `/usr/lib/xinit/services` by default. A file named
`demo.xsh` is loaded by `xinit start demo` or `xinit supervise demo`.

Each file exports one `service` record. This is a hard break from the older
`services` list format. See `docs/demo-service.xsh` for a minimal service
module.

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

Service kinds are `longrun`, `oneshot`, and `scripted`. A service module may
also export lifecycle procs:

```xsh
export proc start() [fs, process, env, error] -> Result[Unit]
export proc stop() [fs, process, env, time, error] -> Result[Unit]
export proc reload() [fs, process, env, error] -> Result[Unit]
export proc finish() [fs, process, env, error] -> Result[Unit]
export proc ready() [fs, process, env, time, error] -> Result[Bool]
export proc status() [fs, process, env, error] -> Result[Str]
```

Dependency fields are:

- `need`: required dependencies; `start SERVICE` starts them first.
- `uses`: optional facility-style dependencies; this is named `uses` because
  `use` is an XSH keyword.
- `after`: ordering-only dependencies.
- `before`: inverse ordering-only dependencies.

Built-in facility names are `logger`, `net`, `dns`, and `firewall`.
Non-facility dependencies must resolve to service files. Cycles and missing
dependencies are errors.

Restart modes are `always`, `on_failure`, and `never`.

`supervise SERVICE` and `scan [SERVICE|TARGET]` are the same scanner: a process
that holds a set of units and reconciles each toward its desired state on every
wakeup, applying restart/backoff policy on child exits and shutting its units
down (in reverse dependency order) on `SIGTERM` or `SIGINT`. `supervise` holds a
single service; `scan` holds a whole dependency tree (a `TARGET`'s services, or
a `SERVICE` plus its dependencies) in one process, each unit backed off
independently. The scanner is the source of truth for the services it owns and
writes their status JSON. See `docs/SUPERVISION.md` for the model.

Restart backoff is exponential. After a crash the scanner waits `delay_ms`
before relaunching and doubles that delay on each successive crash, capped at
`max_delay_ms` (`max_delay_ms: 0` means no cap). A run that stayed up for at
least `stable_after_ms` is treated as healthy and resets the delay back to
`delay_ms`, so a long-lived service that finally crashes does not inherit a
stale long delay. `delay_ms: 0` disables backoff and restarts immediately. The
delay is a non-blocking `next_ms` gate, not a sleep: backing one unit off never
blocks reconciling, stopping, or starting another, and a unit awaiting respawn
reports state `dead`.

Readiness has two forms. By default a longrun is ready as soon as it is spawned
(or, if it exports `ready()`, when that returns true within `ready_timeout_ms`).
Setting `readiness: "notify"` opts into an edge-triggered contract: the scanner
spawns the service with an inherited readiness pipe whose fd number is published
as the `NOTIFY_FD` environment variable, the service writes any byte to that fd
when ready, and until then the unit sits in state `starting`. If the service
does not signal within `ready_timeout_ms`, the scanner promotes it to `running`
but leaves `ready` false rather than wedging. Readiness is reported by `status`
and `list`.

The scanner gates each service's first start on its dependencies' readiness: a
unit is not spawned until its ordering dependencies are up. A `need` dependency
must reach `running` (its startup, including readiness, has completed); `uses`
and `after` dependencies may also be `stopped` (settled), since they are
optional or ordering-only and must not block forever. Dependencies that are not
part of the scanned set (facilities, or services outside this scan) impose no
gate. Only the initial start waits — a respawn is not re-gated, and a dependency
crashing does not stop an already-running dependent.

On stop, the owned process group is sent `TERM`, then `KILL` after
`stop_timeout_ms` (default 200ms) when no custom `stop()` hook exists.

`reload SERVICE` refreshes a running service in place: it runs the service's
`reload()` hook if it exports one, otherwise sends `SIGHUP` to the saved process
group. It does not restart the service or change its state.

While a scanner owns a run directory (tracked by a live `scanner.json` marker),
`start`/`stop`/`restart`/`reload SERVICE` do not act directly — they post a
desired-state request (`up`/`down`/`restart`/`reload`) to
`${XINIT_RUN_DIR}/inbox/SERVICE`, which the scanner drains on its next pass and
applies as the source of truth. Without a live scanner,
`start`/`stop` keep their standalone behavior.

Log modes are `append` and `off`. Missing `logging` means `append`; `off`
disables builtin capture. Append logging is owned by `xinit`: service stdout
and stderr are appended as raw combined bytes to
`${XINIT_LOG_ROOT}/SERVICE/current`, with `XINIT_LOG_ROOT` defaulting to
`/var/log`. The service log directory is created as `0755`, and `current` is
created as `0600`. If append logging cannot create or open the file, service
start fails.

Append logs are size-capped. The `log: {mode: "append", max_size, keep}` form
configures rotation: when `current` reaches `max_size` bytes it is rotated to
`current.1` (older copies shift to `current.2` … `current.<keep>`, oldest
dropped). Defaults are `max_size: 1048576` (1 MiB) and `keep: 3`; `max_size: 0`
disables rotation (unbounded). A service is rotated before each (re)start, and a
scanner additionally rotates a running service's log mid-run via copy-truncate
(a write landing between the copy and the truncate may be lost — the accepted
tradeoff for in-process rotation without log reopen). One-shot `start` outside a
scanner only rotates at start. Compression, timestamps, and line framing are not
implemented yet.

Cgroups v2 support `resources: {cpu_max: N}` for service process-tree CPU
quota. `N` is a percentage of one CPU, matching `run --cpumax`. Linux enforces
the limit with cgroups v2; macOS accepts it as a no-op. V1 still rejects
arbitrary cgroup policy and reserved fields: `delegate`, `slice`, non-empty
`cgroup`, non-empty `cgroup_path`, and memory, pids, or CPU-weight resource
fields.

`boot` starts all services that declare the selected target, with `boot` as the
default target. `start` plans dependencies first, starts them, then starts the
requested service. If a service exports `ready()`, dependents wait until it
returns true or the ready timeout expires. If no `ready()` exists, spawned means
ready. `stop` refuses to stop a service while running dependents require it.
When a service cgroup is created, the resolved `cgroup_path` is included in the
status JSON. `stop` sends `TERM`, then `KILL`, to the saved process group when
no custom `stop()` exists.

Saved status is reconciled against the kernel on every read. A state recorded as
`running` with a tracked pid is only trusted when that pid is still alive
(probed with signal 0) and, when `start` recorded the child's kernel start time,
still has that same start time. A process that crashed without cleanup, or whose
pid was recycled into an unrelated process, reconciles to state `dead` with the
pid cleared. This stops `status` reporting a phantom, stops `stop` signalling an
unrelated recycled pid, and lets `start` relaunch a service whose saved state
went stale. The start-time check is what closes the recycle window the liveness
probe alone leaves open; it is recorded only by the one-shot `start` path (the
scanner clears a service's pid the instant its child exits, so it has no stale
window). A tracked pid of `0` (a completed `oneshot`/`scripted` service) is left
as `running`. Reconciliation is skipped under `XSH_UNIX_DRY_RUN`, where pids are
mocked.

A service module may export a `finish()` hook; xinit runs it after the service's
instance exits — on a clean stop and on a crash — for cleanup that must follow
the process (the unit is reported as `finishing` while it runs).

`status` prints one line:

```text
demo running pid=1000 ready=true log=append desired=up restarts=0
```
