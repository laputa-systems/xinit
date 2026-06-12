# Supervision Redesign

Status: implemented (migration steps 1–5 done; a few follow-ups noted at the end
of the Migration path). This documents the direction for unifying xinit's two
runtime paths around a single supervision model, taking the one idea from
s6/runit that most improves robustness while keeping xinit small. The service
supervisor is now the `ServiceUnit` scanner described below (`scan`/`supervise`);
the inittab engine remains a parallel specialized scanner. The new `unix`/`time`
primitives the scanner relies on were added to the xsh interpreter in the same
effort.

## Problem

`xinit` currently has two unrelated ways a long-running service runs:

- `xinit start SERVICE` spawns a process group, records its pid in
  `/run/xinit/SERVICE.json`, and exits. Nothing watches the process
  afterward. If it crashes, it stays dead until something runs `start` again.
- `xinit supervise SERVICE` runs a long-lived loop that holds one service and
  restarts it on exit.

So the canonical "service is running" state is a pid written to a JSON file by
a process that has already exited. That has two consequences:

1. **State can lie.** `read_status` trusts the saved pid. If the daemon died
   and the kernel recycled the pid, `status` reports a healthy service that is
   gone, and `stop` sends `TERM`/`KILL` to whatever now owns that pid. At PID 1
   that is a real foot-gun.
2. **Two divergent code paths.** The inittab `respawn` engine (`spawn_entries`,
   the `run_pid1` loop) and the service supervisor (`supervise_service`) are
   two separate implementations of "keep a process alive," with separate
   restart logic, separate state, and separate bugs.

The inittab path is itself a crude, in-memory supervisor: it tracks owned pids,
applies a respawn delay through a `next_ms` gate, and relaunches on child exit.
The service path reimplements the same idea per-service. They should be the
same mechanism.

## The idea worth borrowing from s6

In s6 and runit, **the supervisor process is the source of truth**, not a
pidfile. Every long-run service is held open by a dedicated, always-present
supervisor (`s6-supervise`). A scanner (`s6-svscan`) watches a scan directory
and guarantees each service has a live supervisor, restarting the supervisor
itself if it dies. Control happens by talking to the supervisor (over a FIFO in
s6), never by reading a pid from a file and signalling it. State cannot go
stale because the entity that knows the truth is always alive and is the same
entity that owns the child.

xinit already has the pieces: `run_pid1` is effectively a scanner for inittab
entries, and `supervise_service` is effectively one supervisor. The redesign is
to make that relationship explicit and shared rather than duplicated.

## Proposed model

### One scanner, one supervisor mechanism

`run_pid1` becomes the scanner. Instead of two notions of "owned process," it
reconciles a set of **supervised units** toward their desired state. A unit is
either an inittab process entry (`respawn`/`once`/`poweroff`) or a service the
operator brought up. Each unit carries the state the supervisor needs:

- the command / process group it owns,
- desired state (`up` / `down` / `once`),
- restart policy (mode + the existing `delay_ms` / `max_delay_ms` /
  `stable_after_ms` backoff, which is now honored — see `INIT.md`),
- backoff bookkeeping (`current_delay`, `started_at`).

The reconcile step is the logic already in `spawn_entries` + the backoff added
to `supervise_service`, generalized to operate on units: for each unit whose
desired state is `up` and whose process is dead and whose backoff gate has
elapsed, (re)spawn it. This removes the second implementation entirely;
`supervise_service` collapses into "register a unit with the scanner."

### Control plane: ask the supervisor, do not signal a pidfile

Control commands (`start`, `stop`, `restart`, `reload`) stop writing a pid and
hoping. They submit a desired-state change to the scanner, which owns the
child and acts on it. Concretely, the run directory holds a small command
inbox per unit (a directory the scanner drains, or — if/when the `unix` module
grows a control-fd primitive — a fifo, matching `s6-svc`). The scanner is the
only writer of authoritative state. `status` reports what the scanner knows,
not a possibly-stale pid.

This also fixes the staleness class directly: because the scanner holds the
child and reaps it, it knows the instant a service dies and updates state then,
rather than a reader inferring liveness from a recycled pid.

### Readiness: keep `ready()`, add an fd notification

The current `ready()` poll (100 ms loop, `wait_ready`) stays as the simple
option. Add s6's `notification-fd` / `sd_notify`-style readiness as the
edge-triggered option: the service writes a byte to an inherited fd when it is
ready, and the supervisor treats that as the readiness signal with no polling.
Ordering dependents wait on readiness either way. This is strictly additive.

### State machine

Make the lifecycle explicit and enforced rather than loose strings:

```
down -> starting -> up -> ready -> finishing -> down
```

`starting` covers spawn + the ready wait; `ready` is reached via `ready()` or
the notification fd (or immediately if neither is declared, matching today).
`finishing` runs the existing `stop()` hook (and a future optional `finish`
hook) with a per-service stop timeout instead of the current hardcoded 200 ms.

### Head-of-line blocking is gone

Backoff is now a per-unit `next_ms` gate checked on each reconcile pass — the
same trick the inittab path uses — not a blocking sleep. The scanner sleeps with
`unix.wait_pid1_event(timeout:)` until the soonest gate (or wakes early on a
signal or child exit), so idle trees do not spin and a due relaunch is not
delayed by the old fixed 100ms poll. Backing one unit off never blocks stopping
or starting another.

## Migration path

1. (done) Honor the restart backoff fields so the single-service path is correct
   on its own.
2. (done) `read_status` reconciles the saved pid against the kernel (signal-0
   liveness probe), so `status`/`stop`/`start` stop trusting a stale or recycled
   pid. The `start` path now also records the child's kernel start time
   (`process.list`) and `read_status` verifies it, closing the recycle window the
   liveness probe alone leaves open. The scanner does not need this — it clears a
   service's pid the instant its child exits.
3. (done) Introduced the `ServiceUnit` abstraction and a single non-blocking
   `reconcile`/`mark_unit_dead`/`stop_unit` core. `supervise` is now a one-unit
   scanner; `scan [SERVICE|TARGET]` supervises a whole dependency tree as N units
   in one process with independent per-unit backoff. The inittab engine
   (`spawn_entries`/`run_pid1`) stays a parallel specialized scanner and shares
   the `spawn_due` backoff/respawn timing gate with the service scanner. Full
   unification (inittab entries as synthetic `ServiceUnit`s) was deliberately
   declined: XSH has no first-class closures, so a shared reconcile cannot take
   the spawn mechanism as a strategy and would instead branch on inittab-only
   fields (`tty`, poweroff-on-exit, launch caps) while the two engines gate
   differently (raw-pid tracking vs a desired-state machine). Forcing them
   together would pollute the service model and require rewriting the
   boot-critical PID 1 tests, for dedup rather than a fix. The genuinely common,
   behavior-preserving mechanic (`spawn_due`) is shared; the divergent policy
   (tty, flat-vs-exponential backoff, launch limits, the sysinit/wait/shutdown
   phases, restart-exec, halt/poweroff/reboot) stays local to each engine.
4. (done) Control inbox: the scanner drains `${XINIT_RUN_DIR}/inbox/<service>`
   request files (`up`/`down`) each pass and is the source of truth via a
   `scanner.json` liveness marker. `start`/`stop` post a desired-state request
   instead of acting directly when a live scanner owns the run directory;
   without one they keep their standalone behavior.
5. (done) Notification-fd readiness and an explicit `starting`/`running` state.
   A `readiness: "notify"` service is spawned with an inherited readiness pipe
   (`unix.spawn_process_group(..., notify: true)`, the write end named by
   `NOTIFY_FD`); the unit sits in `starting` until it writes its byte
   (`unix.notify_ready`) or its `ready_timeout_ms` elapses, then becomes
   `running`. Per-service `stop_timeout_ms` replaces the hardcoded 200ms
   TERM→KILL grace, and the scanner waits with a computed deadline rather than a
   fixed poll. The three `unix`/`time` primitives this needed were implemented in
   the xsh interpreter (`time.millis`/`time.seconds`,
   `unix.wait_pid1_event(timeout:)`, and the spawn `notify` fd +
   `unix.notify_ready`/`unix.notify_close`).

Dependency-ordered readiness gating is now done: the scanner gates each unit's
first start (`gate_satisfied`) until its `need` deps are `running` and its
`uses`/`after` deps are settled, and skips blocked-pending units when computing
its wait so it does not spin. Respawns are not re-gated.

Size-capped logs (rotate-on-spawn plus a scanner copy-truncate pass) and the
`finishing` state with a `finish()` cleanup hook are also done.

Follow-ups still open: surfacing notify readiness as a `wait_pid1_event` event so
the scanner need not poll the fd at all (it currently polls on a bounded 100ms
cadence); and dependency-triggered restart (stopping/restarting a dependent when
a dependency it `need`s goes down — deliberately not done, matching the current
"first start only" gating).

Each step was independently shippable and testable; nothing required a big-bang
rewrite.

## Non-goals

Deliberately *not* borrowed, to keep xinit small and inspectable:

- **s6-rc offline compilation.** xinit resolves dependencies at runtime from
  service files. That is more inspectable for a small system; keep it.
- **execline.** XSH already gives structured, no-shell-string execution at
  PID 1.
- **Separate logging service layer (runit-style `log/` dirs).** xinit owns log
  capture in-process by design. Rotation/retention should extend the built-in
  log path, not add a per-service logger to wire by hand.
- **Socket activation.** A systemd concept, not an s6 one, and out of scope for
  this system. Document it as a non-goal rather than leaving it ambiguous.
