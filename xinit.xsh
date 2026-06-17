#!/usr/local/bin/xsh --
error XinitError = Failed(kind: Str, message: Str)

type InittabEntry = {key: Str, id: Str, action: Str, command: Str, argv: List[Str]}

type RuntimeEntry = {key: Str, pid: Int, launches: Int, next_ms: Int, action: Str}

type Service = {
  name: Str,
  path: Path,
  kind: Str,
  command: Command,
  restart_mode: Str,
  targets: List[Str],
  need: List[Str],
  uses: List[Str],
  after: List[Str],
  before: List[Str],
  delay_ms: Int,
  max_delay_ms: Int,
  stable_after_ms: Int,
  stop_timeout_ms: Int,
  log: Str,
  log_max_size: Int,
  log_keep: Int,
  cpu_max: Int,
  ready_timeout_ms: Int,
  readiness: Str,
}

type ServiceFile = module {
  export let service: Record
  export optional proc start() [fs, process, env, error] -> Result[Unit]
  export optional proc stop() [fs, process, env, time, error] -> Result[Unit]
  export optional proc reload() [fs, process, env, error] -> Result[Unit]
  export optional proc finish() [fs, process, env, error] -> Result[Unit]
  export optional proc ready() [fs, process, env, time, error] -> Result[Bool]
  export optional proc status() [fs, process, env, error] -> Result[Str]
}

type SavedStatus = {
  name: Str,
  desired: Str,
  state: Str,
  pid: Int,
  supervisor_pid: Int,
  log: Str,
  restarts: Int,
  ready: Bool,
  cgroup_path: Str,
  start_time_ms: Int,
}

# Result of spawning a service instance: the saved status plus the readiness
# notification fd (>0 only for a `readiness: "notify"` service spawned under the
# scanner; -1 otherwise).
type SpawnResult = {status: SavedStatus, notify_fd: Int}

# A supervised unit: a service plus the runtime state the scanner needs to keep
# it at its desired state. `state` is the internal lifecycle (pending -> starting
# -> running -> dead -> running, or -> stopped); `next_ms`/`current_delay`/
# `started_at` drive non-blocking restart backoff (a future-dated `next_ms` gate
# replaces the blocking sleep the single-service supervisor used to do).
# `notify_fd` holds the readiness pipe while a unit is `starting`. See
# docs/SUPERVISION.md.
type ServiceUnit = {
  service: Service,
  desired: Str,
  state: Str,
  pid: Int,
  restarts: Int,
  ready: Bool,
  cgroup_path: Str,
  next_ms: Int,
  current_delay: Int,
  started_at: Int,
  notify_fd: Int,
}

pure usage_text() -> Str {
  return """xinit 0.0.1

Usage:
  xinit [INITTAB]
  xinit boot [TARGET]
  xinit scan [SERVICE|TARGET]
  xinit <start|up|stop|down|restart|reload|status|logs|supervise> SERVICE
  xinit <list|graph> [SERVICE|TARGET]
  xinit check [SERVICE|PATH]
"""
}

proc env_value(name: Str, fallback: Str) [env] -> Str {
  match env.get(name) {
    Ok(value) => {
      if value.trim() != "" {
        return value
      }
    }
    Err(_) => {}
  }

  return fallback
}

proc env_enabled(name: Str) [env] -> Bool {
  let value = env_value(name, "")
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc env_int(name: Str, fallback: Int) [env, error] -> Result[Int] {
  let value = env_value(name, "")

  if value == "" {
    return fallback
  }

  return value.parse_int()?
}

proc service_dir() [env, error] -> Result[Path] {
  return Path.parse(env_value("XINIT_SERVICE_DIR", "/usr/lib/xinit/services"))?
}

proc run_dir() [env, error] -> Result[Path] {
  return Path.parse(env_value("XINIT_RUN_DIR", "/run/xinit"))?
}

proc log_root() [env, error] -> Result[Path] {
  return Path.parse(env_value("XINIT_LOG_ROOT", "/var/log"))?
}

proc inbox_dir() [env, error] -> Result[Path] {
  return fp"${run_dir()?.display()}/inbox"
}

proc scanner_marker_path() [env, error] -> Result[Path] {
  return fp"${run_dir()?.display()}/scanner.json"
}

pure command_from_argv(argv: List[Str]) -> Command {
  return process.command_argv(argv[0], argv)
}

pure entry_spawns(entry: InittabEntry) -> Bool {
  return entry.action == "once" or entry.action == "respawn" or entry.action == "poweroff"
}

proc parse_inittab_line(line: Str, index: Int) [process, error] -> Result[InittabEntry] {
  let trimmed = line.split("#")[0].trim()

  if trimmed == "" {
    return {key: "", id: "", action: "", command: "", argv: [""]}
  }

  let fields = trimmed.split(":")

  if fields.len() < 2 {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: missing runlevels"))
  }

  if fields.len() < 3 {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: missing action"))
  }

  if fields.len() < 4 {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: missing command"))
  }

  let action = fields[2].trim()

  if ! (action == "sysinit" or action == "wait" or action == "once" or action == "restart" or action == "shutdown" or action == "respawn" or action == "poweroff") {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: unsupported action '${action}'"))
  }

  let command = (fields |> drop(3)).join(":").trim()

  if command == "" {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: missing command"))
  }

  let argv = process.argv_words(command)?

  if argv.len() == 0 or argv[0] == "" {
    return Err(XinitError.Failed("init-inittab", f"line ${index}: missing command"))
  }

  return {key: f"${index}:${fields[0].trim()}", id: fields[0].trim(), action, command, argv}
}

proc parse_inittab(path_value: Path) [fs, process, error] -> Result[List[InittabEntry]] {
  var entries: List[InittabEntry] = []
  var index = 1

  for line in path_value.read_text()?.lines() {
    let entry = parse_inittab_line(line, index)?

    if entry.action != "" {
      entries = entries.push(entry)
    }

    index += 1
  }

  return entries
}

proc run_phase(entries: List[InittabEntry], action: Str) [process, error] {
  for entry in entries {
    if entry.action == action {
      let status = process.run(command_from_argv(entry.argv))?

      if ! status.ok {
        return Err(XinitError.Failed("init-entry-failed", entry.command))
      }
    }
  }
}

pure runtime_get(runtime: List[RuntimeEntry], key: Str) -> RuntimeEntry {
  for item in runtime {
    if item.key == key {
      return item
    }
  }

  return {key, pid: -1, launches: 0, next_ms: 0, action: ""}
}

proc runtime_set(runtime: List[RuntimeEntry], value: RuntimeEntry) [error] -> List[RuntimeEntry] {
  var out: List[RuntimeEntry] = []
  var found = false

  for item in runtime {
    if item.key == value.key {
      out = out.push(value)
      found = true
    } else {
      out = out.push(item)
    }
  }

  if ! found {
    out = out.push(value)
  }

  return out
}

# The shared (re)spawn timing gate: a tracked process is due when it holds no
# live pid and its backoff/respawn deadline has elapsed. Both the inittab respawn
# engine and the service scanner gate on this; each then layers its own policy on
# top (inittab: per-action launch limits; scanner: desired state + restart mode).
pure spawn_due(pid: Int, now: Int, next_ms: Int) -> Bool {
  return pid <= 0 and now >= next_ms
}

proc spawn_entries(
  entries: List[InittabEntry],
  runtime: List[RuntimeEntry],
  launch_limit: Int,
  delay_ms: Int,
) [process, time, error] -> Result[List[RuntimeEntry]] {
  var out = runtime
  let now = time.now()

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(out, entry.key)

      let launch_allowed = if entry.action == "respawn" {
        launch_limit == 0 or current.launches < launch_limit
      } else {
        current.launches == 0
      }

      if spawn_due(current.pid, now, current.next_ms) and launch_allowed {
        let command = command_from_argv(entry.argv)

        let child = if entry.id == "" {
          unix.spawn_process_group(command)?
        } else {
          unix.spawn_with_tty(command, tty: entry.id)?
        }

        out = runtime_set(
          out,
          {
            key: entry.key,
            pid: child.pid,
            launches: current.launches + 1,
            next_ms: now + delay_ms,
            action: entry.action,
          },
        )
      }
    }
  }

  return out
}

proc mark_dead(entries: List[InittabEntry], runtime: List[RuntimeEntry], pid: Int) [error] -> Record {
  var out = runtime
  var event = ""

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(out, entry.key)

      if current.pid == pid {
        out = runtime_set(
          out,
          {key: entry.key, pid: -1, launches: current.launches, next_ms: current.next_ms, action: entry.action},
        )

        if entry.action == "poweroff" {
          event = "poweroff"
        }
      }
    }
  }

  return {runtime: out, event}
}

pure should_exit_idle(
  entries: List[InittabEntry],
  runtime: List[RuntimeEntry],
  exit_when_idle: Bool,
  launch_limit: Int,
) -> Bool {
  if ! exit_when_idle {
    return false
  }

  for entry in entries {
    if entry.action == "respawn" {
      let current = runtime_get(runtime, entry.key)

      if current.pid > 0 {
        return false
      }

      if launch_limit == 0 or current.launches < launch_limit {
        return false
      }
    }
  }

  return true
}

proc shutdown_runtime(entries: List[InittabEntry], runtime: List[RuntimeEntry], fast: Bool) [process, error] {
  var groups: List[Int] = []

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(runtime, entry.key)

      if current.pid > 0 {
        groups = groups.push(current.pid)
      }
    }
  }

  if groups.len() > 0 {
    let timeout = if fast { 0ms } else { 2s }
    let _ = unix.shutdown_process_groups(groups, timeout)?
  }
}

proc finalize(kind: Str) [fs, process, env, time, error] {
  let action_log = env_value("XSH_INIT_TEST_ACTION_LOG", "")

  if action_log != "" {
    Path.parse(action_log)?.write(f"""${kind}
""")?

    return
  }

  if env_enabled("XSH_INIT_FINAL_CLEANUP") or env_value("XSH_INIT_FINAL_CLEANUP", "") == "" {
    linux.kill_all(signal: "TERM", except_pid1: true)?
    time.sleep(2s)?
    linux.kill_all(signal: "KILL", except_pid1: true)?
  }

  if kind == "halt" {
    linux.halt()?
  } else if kind == "poweroff" {
    linux.poweroff()?
  } else if kind == "reboot" {
    linux.reboot()?
  }
}

proc run_pid1(inittab: Path) [fs, process, env, time, error] {
  let allow = env_enabled("XINIT_TEST_ALLOW_NON_PID1") or env_enabled("XSH_INIT_TEST_ALLOW_NON_PID1")
  unix.pid1_setup(["HUP", "TERM", "USR1", "USR2", "INT"], subreaper: true, allow_non_pid1: allow)?
  let entries = parse_inittab(inittab)?
  let launch_limit = env_int("XSH_INIT_TEST_MAX_RESPAWNS", 0)?
  let delay_ms = env_int("XSH_INIT_TEST_RESPAWN_DELAY_MS", 1000)?
  let exit_when_idle = env_enabled("XSH_INIT_TEST_EXIT_WHEN_IDLE")
  let fast = env_enabled("XSH_INIT_FAST_SHUTDOWN")
  var runtime: List[RuntimeEntry] = []
  var event = ""
  run_phase(entries, "sysinit")?
  run_phase(entries, "wait")?
  runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?

  if should_exit_idle(entries, runtime, exit_when_idle, launch_limit) {
    return
  }

  while event == "" {
    let pid_event = unix.wait_pid1_event()?

    if pid_event.kind == "signal" {
      if pid_event.signal == "HUP" {
        event = "restart"
      } else if pid_event.signal == "USR1" {
        event = "halt"
      } else if pid_event.signal == "USR2" or pid_event.signal == "INT" {
        event = "poweroff"
      } else if pid_event.signal == "TERM" {
        event = "reboot"
      }
    } else if pid_event.kind == "children" {
      for child in pid_event.children {
        let marked = mark_dead(entries, runtime, child.pid)
        runtime = marked.runtime

        if marked.event != "" {
          event = marked.event
        }
      }
    }

    if event == "" {
      runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?

      if should_exit_idle(entries, runtime, exit_when_idle, launch_limit) {
        return
      }
    }
  }

  shutdown_runtime(entries, runtime, fast)?

  if event == "restart" {
    for entry in entries {
      if entry.action == "restart" {
        unix.exec(command_from_argv(entry.argv))?
      }
    }

    return
  }

  run_phase(entries, "shutdown")?
  finalize(event)?
}

proc service_path(target: Str) [env, error] -> Result[Path] {
  if "/" in target or target.ends_with(".xsh") {
    return Path.parse(target)?
  }

  return fp"${service_dir()?.display()}/${target}.xsh"
}

pure builtin_facilities() -> List[Str] {
  return ["logger", "net", "dns", "firewall"]
}

proc require_service_file(path_value: Path) [fs, error] {
  if ! path_value.exists()? {
    return Err(
      XinitError.Failed(
        "xinit-service",
        f"failed to read service file '${path_value.display()}': No such file or directory",
      ),
    )
  }
}

proc service_from_record(path_value: Path, raw: Record) [process, error] -> Result[Service] {
  let checked = record.require(
    raw,
    {name: "Str"},
    optional: {
      kind: "Str",
      command: "Command",
      restart: "Record",
      logging: "Str",
      log: "Record",
      targets: "List[Str]",
      dependencies: "Record",
      resources: "Record",
      ready_timeout_ms: "Int",
      stop_timeout_ms: "Int",
      readiness: "Str",
    },
    source: path_value,
  )?

  let kind: Str = if checked.has("kind") { checked.kind } else { "longrun" }

  let command: Command = if checked.has("command") {
    checked.command
  } else {
    process.command_argv("/bin/true", ["true"])
  }

  var restart_mode = if kind == "longrun" { "on_failure" } else { "never" }
  var delay_ms = 1000
  var max_delay_ms = 30000
  var stable_after_ms = 10000

  if checked.has("restart") {
    let restart = record.require(
      checked.restart,
      {},
      optional: {mode: "Str", delay_ms: "Int", max_delay_ms: "Int", stable_after_ms: "Int"},
      source: path_value,
    )?

    if restart.has("mode") {
      restart_mode = restart.mode
    }

    if restart.has("delay_ms") {
      delay_ms = restart.delay_ms
    }

    if restart.has("max_delay_ms") {
      max_delay_ms = restart.max_delay_ms
    }

    if restart.has("stable_after_ms") {
      stable_after_ms = restart.stable_after_ms
    }
  }

  var log_mode = "append"

  # Built-in append logs are bounded by default: rotate `current` once it reaches
  # `max_size` bytes, keeping `keep` rotated files. `max_size: 0` disables
  # rotation (unbounded, the old behavior).
  var log_max_size = 1048576
  var log_keep = 3

  if checked.has("logging") {
    log_mode = checked.logging
  } else if checked.has("log") {
    let log = record.require(checked.log, {mode: "Str"}, optional: {max_size: "Int", keep: "Int"}, source: path_value)?
    log_mode = log.mode

    if log.has("max_size") {
      log_max_size = log.max_size
    }

    if log.has("keep") {
      log_keep = log.keep
    }
  }

  if log_mode == "off" {
    log_mode = "none"
  }

  let targets: List[Str] = if checked.has("targets") { checked.targets } else { [] }
  var need: List[Str] = []
  var uses: List[Str] = []
  var after: List[Str] = []
  var before: List[Str] = []

  if checked.has("dependencies") {
    let deps = record.require(
      checked.dependencies,
      {},
      optional: {need: "List[Str]", uses: "List[Str]", after: "List[Str]", before: "List[Str]"},
      source: path_value,
    )?

    if deps.has("need") {
      need = deps.need
    }

    if deps.has("uses") {
      uses = deps.uses
    }

    if deps.has("after") {
      after = deps.after
    }

    if deps.has("before") {
      before = deps.before
    }
  }

  var cpu_max = 0

  if checked.has("resources") {
    let resources = record.require(checked.resources, {}, optional: {cpu_max: "Int"}, source: path_value)?

    if resources.has("cpu_max") {
      cpu_max = resources.cpu_max
    }
  }

  let ready_timeout_ms = if checked.has("ready_timeout_ms") { checked.ready_timeout_ms } else { 5000 }
  let stop_timeout_ms = if checked.has("stop_timeout_ms") { checked.stop_timeout_ms } else { 200 }
  let readiness = if checked.has("readiness") { checked.readiness } else { "auto" }

  return {
    name: checked.name,
    path: path_value,
    kind,
    command,
    restart_mode,
    targets,
    need,
    uses,
    after,
    before,
    delay_ms,
    max_delay_ms,
    stable_after_ms,
    stop_timeout_ms,
    log: log_mode,
    log_max_size,
    log_keep,
    cpu_max,
    ready_timeout_ms,
    readiness,
  }
}

proc load_service_path(path_value: Path) [fs, process, env, error] -> Result[Service] {
  require_service_file(path_value)?
  let loaded = module.load(path_value)?.require(ServiceFile)?
  return service_from_record(path_value, loaded.service)?
}

proc load_service(target: Str) [fs, process, env, error] -> Result[Service] {
  let path_value = service_path(target)?
  let service = load_service_path(path_value)?

  if "/" in target or target.ends_with(".xsh") or service.name == target {
    return service
  }

  return Err(
    XinitError.Failed(
      "xinit-service",
      f"service file '${path_value.display()}' defines '${service.name}', not '${target}'",
    ),
  )
}

proc all_services() [fs, process, env, error] -> Result[List[Service]] {
  let dir = service_dir()?
  var out: List[Service] = []

  if ! dir.exists()? {
    return out
  }

  for entry in fs.children(dir)?
    |> where .kind == "file" and .name.ends_with(".xsh")
    |> sort-by .name {
    out = out.push(load_service_path(entry.path)?)
  }

  return out
}

pure service_names(services: List[Service]) -> List[Str] {
  return [service.name for service in services]
}

pure contains_name(services: List[Service], name: Str) -> Bool {
  for service in services {
    if service.name == name {
      return true
    }
  }

  return false
}

pure find_loaded_service(services: List[Service], name: Str) -> Result[Service] {
  for service in services {
    if service.name == name {
      return service
    }
  }

  return Err(XinitError.Failed("xinit-service", f"unknown service '${name}'"))
}

pure required_dependencies(service: Service) -> List[Str] {
  return service.need.extend(service.uses)
}

pure dependency_edges(service: Service) -> List[Str] {
  return service.need.extend(service.uses).extend(service.after)
}

proc check_service_graph(services: List[Service]) [error] {
  let names = service_names(services)
  let facilities = builtin_facilities()

  for service in services {
    for dep in dependency_edges(service).extend(service.before) {
      if ! names.contains(dep) and ! facilities.contains(dep) {
        return Err(XinitError.Failed("xinit-deps", f"${service.name}: unknown dependency '${dep}'"))
      }
    }
  }
}

pure visit_plan(
  services: List[Service],
  name: Str,
  stack: List[Str],
  done: List[Str],
  out: List[Str],
) -> Result[Record] {
  if done.contains(name) {
    return {done, out}
  }

  if stack.contains(name) {
    return Err(XinitError.Failed("xinit-deps", f"dependency cycle: ${stack.push(name).join(" -> ")}"))
  }

  let service = find_loaded_service(services, name)?
  var next_done = done
  var next_out = out

  for dep in dependency_edges(service) {
    if contains_name(services, dep) {
      let planned = visit_plan(services, dep, stack.push(name), next_done, next_out)?
      next_done = planned.done
      next_out = planned.out
    }
  }

  for candidate in services {
    if candidate.before.contains(name) {
      let planned = visit_plan(services, candidate.name, stack.push(name), next_done, next_out)?
      next_done = planned.done
      next_out = planned.out
    }
  }

  next_done = next_done.push(name)
  next_out = next_out.push(name)
  return {done: next_done, out: next_out}
}

# Names that must start for `name` to be considered up: the root plus its
# transitive `need` closure. `uses` deps are deliberately excluded — they are
# optional, so their start failure is tolerated (see start_service).
pure required_closure(services: List[Service], name: Str, out: List[Str]) -> Result[List[Str]] {
  if out.contains(name) {
    return out
  }

  var next = out.push(name)
  let service = find_loaded_service(services, name)?

  for dep in service.need {
    if contains_name(services, dep) {
      next = required_closure(services, dep, next)?
    }
  }

  return next
}

proc required_names(name: Str) [fs, process, env, error] -> Result[List[Str]] {
  var services = all_services()?

  if ! contains_name(services, name) {
    services = services.push(load_service(name)?)
  }

  return required_closure(services, name, [])?
}

proc plan_service_start(name: Str) [fs, process, env, error] -> Result[List[Str]] {
  var services = all_services()?

  if ! contains_name(services, name) {
    services = services.push(load_service(name)?)
  }

  check_service_graph(services)?
  let planned = visit_plan(services, name, [], [], [])?
  return planned.out
}

proc plan_target_start(target: Str) [fs, process, env, error] -> Result[List[Str]] {
  let services = all_services()?
  check_service_graph(services)?
  var out: List[Str] = []
  var done: List[Str] = []

  for service in services {
    if service.targets.contains(target) {
      let planned = visit_plan(services, service.name, [], done, out)?
      done = planned.done
      out = planned.out
    }
  }

  return out
}

proc state_path(name: Str) [env, error] -> Result[Path] {
  return fp"${run_dir()?.display()}/${name}.json"
}

pure default_status(name: Str) -> SavedStatus {
  return {
    name,
    desired: "down",
    state: "down",
    pid: 0,
    supervisor_pid: 0,
    log: "append",
    restarts: 0,
    ready: false,
    cgroup_path: "",
    start_time_ms: 0,
  }
}

# Liveness probe via signal 0. An Ok result means the pid exists and we may
# signal it, i.e. it is plausibly still our running service. Any error means it
# is gone (ESRCH) or no longer ours (EPERM, e.g. the pid was recycled into
# another user's process); in both cases the saved state is stale, so we treat
# it as not alive. xinit runs as root over its own children, so EPERM does not
# arise for legitimately-owned services in practice.
proc pid_alive(pid: Int) [process] -> Bool {
  if pid <= 0 {
    return false
  }

  match process.kill(pid, "0") {
    Ok(_) => true
    Err(_) => false
  }
}

# The kernel start time (epoch ms) of a live pid, or 0 if it is not found.
proc pid_start_time(pid: Int) [process, error] -> Result[Int] {
  if pid <= 0 {
    return 0
  }

  for entry in process.list()? {
    if entry.pid == pid {
      return entry.start_time_ms
    }
  }

  return 0
}

# Whether a tracked pid is still our service instance: alive (signal 0) and, when
# a baseline start time was recorded, with a matching kernel start time. The
# start-time check closes the window the bare liveness probe leaves open when a
# dead service's pid is recycled into an unrelated process. A baseline of 0
# (e.g. scanner-managed units, which clear the pid on child exit) skips it.
proc pid_live_and_ours(pid: Int, start_time_ms: Int) [process, error] -> Result[Bool] {
  if ! pid_alive(pid) {
    return false
  }

  if start_time_ms <= 0 {
    return true
  }

  return pid_start_time(pid)? == start_time_ms
}

proc read_status(name: Str) [fs, process, env, error] -> Result[SavedStatus] {
  let path_value = state_path(name)?

  if ! path_value.exists()? {
    return default_status(name)
  }

  let raw = json.read(path_value)?
  let status_name: Str = json.get(raw, ["name"], name)
  let desired: Str = json.get(raw, ["desired"], "down")
  let state: Str = json.get(raw, ["state"], "down")
  let pid: Int = json.get(raw, ["pid"], 0)
  let supervisor_pid: Int = json.get(raw, ["supervisor_pid"], 0)
  let log: Str = json.get(raw, ["log"], "append")
  let restarts: Int = json.get(raw, ["restarts"], 0)
  let ready: Bool = json.get(raw, ["ready"], state == "running")
  let cgroup_path: Str = json.get(raw, ["cgroup_path"], "")
  let start_time_ms: Int = json.get(raw, ["start_time_ms"], 0)

  let status: SavedStatus = {
    name: status_name,
    desired,
    state,
    pid,
    supervisor_pid,
    log,
    restarts,
    ready,
    cgroup_path,
    start_time_ms,
  }

  # Trust the kernel, not the pidfile. A saved "running" state whose tracked pid
  # is no longer alive is stale (the process crashed without cleanup, or the pid
  # was recycled), so reconcile it to "dead" rather than report a phantom or let
  # `stop` signal an unrelated process. Skipped under XSH_UNIX_DRY_RUN, where
  # pids are mocked and `process.kill` would probe the real kernel. A tracked
  # pid of 0 (completed oneshot/scripted service) is left untouched.
  if status.state == "running" and status.pid > 0 and ! env_enabled("XSH_UNIX_DRY_RUN") and ! pid_live_and_ours(
    status.pid,
    status.start_time_ms,
  )? {
    return {
      name: status.name,
      desired: status.desired,
      state: "dead",
      pid: 0,
      supervisor_pid: status.supervisor_pid,
      log: status.log,
      restarts: status.restarts,
      ready: false,
      cgroup_path: status.cgroup_path,
      start_time_ms: 0,
    }
  }

  return status
}

proc write_status(status: SavedStatus) [fs, process, env, error] {
  let dir = run_dir()?
  dir.mkdir()?
  json.write(state_path(status.name)?, status)?
}

proc status_line(status: SavedStatus) [error] -> Str {
  var line = f"${status.name} ${status.state} pid=${status.pid} ready=${status.ready} log=${status.log} desired=${status.desired} restarts=${status.restarts}"

  if status.supervisor_pid > 0 {
    line = f"${line} supervisor=${status.supervisor_pid}"
  }

  if status.cgroup_path != "" {
    line = f"${line} cgroup=${status.cgroup_path}"
  }

  return line
}

proc log_path(name: Str) [env, error] -> Result[Path] {
  return fp"${log_root()?.display()}/${name}/current"
}

proc rotated_log_path(current: Path, index: Int) [error] -> Result[Path] {
  return fp"${current.display()}.${index}"
}

# Rotate a service's `current` log, keeping `keep` numbered copies
# (current.1 newest). Uses copy-then-truncate so a running child's append fd
# stays valid; a write landing between the copy and the truncate may be lost,
# which is the accepted V1 tradeoff for in-process rotation without log reopen.
proc rotate_log(name: Str, keep: Int) [fs, env, error] {
  let current = log_path(name)?
  rotated_log_path(current, keep)?.remove(missing_ok: true)?
  var index = keep - 1

  while index >= 1 {
    let older = rotated_log_path(current, index)?

    if older.exists()? {
      older.rename(rotated_log_path(current, index + 1)?, overwrite: true)?
    }

    index -= 1
  }

  current.copy(rotated_log_path(current, 1)?, overwrite: true)?
  current.truncate(0)?
}

proc maybe_rotate_log(name: Str, max_size: Int, keep: Int) [fs, env, error] {
  if max_size <= 0 or keep <= 0 {
    return
  }

  let current = log_path(name)?

  if ! current.exists()? {
    return
  }

  if current.metadata()?.size >= max_size {
    rotate_log(name, keep)?
  }
}

proc wait_ready(service: Service) [fs, process, env, time, error] -> Result[Bool] {
  require_service_file(service.path)?
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if ! loaded.has("ready") {
    return true
  }

  let deadline = time.now() + service.ready_timeout_ms

  while time.now() <= deadline {
    if loaded.ready()? {
      return true
    }

    time.sleep(100ms)?
  }

  return false
}

proc run_start_proc(service: Service) [fs, process, env, error] -> Result[Bool] {
  require_service_file(service.path)?
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if loaded.has("start") {
    loaded.start()?
    return true
  }

  return false
}

proc run_stop_proc(service: Service) [fs, process, env, time, error] -> Result[Bool] {
  require_service_file(service.path)?
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if loaded.has("stop") {
    loaded.stop()?
    return true
  }

  return false
}

proc run_reload_proc(service: Service) [fs, process, env, error] -> Result[Bool] {
  require_service_file(service.path)?
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if loaded.has("reload") {
    loaded.reload()?
    return true
  }

  return false
}

# Reload a running service in place: run its `reload()` hook if it has one,
# otherwise send SIGHUP to its process group (the usual reload convention).
proc reload_unit(service: Service, pid: Int) [fs, process, env, error] {
  if run_reload_proc(service)? {} else if pid > 0 {
    unix.kill_process_group(pid, "HUP")?
  }
}

# Spawn one instance of a service. `notify` is set by the scanner; combined with
# a `readiness: "notify"` service it spawns with a readiness pipe and reports the
# child not-yet-ready (the scanner polls the returned `notify_fd`). Otherwise
# readiness is resolved inline via the `ready()` hook (or spawned == ready), and
# `notify_fd` is -1.
proc spawn_service(
  service: Service,
  restarts: Int,
  notify: Bool,
) [fs, process, env, time, error] -> Result[SpawnResult] {
  let cgroup_path = if service.cpu_max > 0 and env_enabled("XSH_UNIX_DRY_RUN") and env_value("XSH_CGROUP_ROOT", "") == "" {
    f"dry-run:/xinit/${service.name}"
  } else {
    ""
  }

  if service.kind == "oneshot" or service.kind == "scripted" {
    if ! run_start_proc(service)? {
      let status = process.run(service.command)?

      if ! status.ok {
        return Err(XinitError.Failed("xinit-service", f"${service.name}: start failed"))
      }
    }

    return {
      status: {
        name: service.name,
        desired: "up",
        state: "running",
        pid: 0,
        supervisor_pid: 0,
        log: service.log,
        restarts,
        ready: wait_ready(service)?,
        cgroup_path,
        start_time_ms: 0,
      },
      notify_fd: -1,
    }
  }

  let use_notify = notify and service.readiness == "notify"

  if service.log == "none" {
    let child = unix.spawn_process_group(service.command, notify: use_notify)?
    let ready = if use_notify { false } else { wait_ready(service)? }

    return {
      status: {
        name: service.name,
        desired: "up",
        state: "running",
        pid: child.pid,
        supervisor_pid: 0,
        log: service.log,
        restarts,
        ready,
        cgroup_path,
        start_time_ms: 0,
      },
      notify_fd: child.notify_fd,
    }
  }

  let path_value = log_path(service.name)?

  match path_value.parent.mkdir() {
    Ok(_) => {}
    Err(err) => return Err(XinitError.Failed("xinit-log", err.message))
  }

  # Rotate before opening so a service that has accumulated a large log across
  # restarts starts a fresh `current` rather than appending to an oversized one.
  maybe_rotate_log(service.name, service.log_max_size, service.log_keep)?
  let child = unix.spawn_process_group_log(service.command, path_value, notify: use_notify)?
  let ready = if use_notify { false } else { wait_ready(service)? }

  return {
    status: {
      name: service.name,
      desired: "up",
      state: "running",
      pid: child.pid,
      supervisor_pid: 0,
      log: service.log,
      restarts,
      ready,
      cgroup_path,
      start_time_ms: 0,
    },
    notify_fd: child.notify_fd,
  }
}

proc start_one_service(name: Str) [fs, process, env, time, error] -> Result[SavedStatus] {
  let current = read_status(name)?

  if current.pid > 0 and current.state == "running" {
    return current
  }

  let service = load_service(name)?

  # CLI start is one-shot and unsupervised: no notify pipe (its read end would
  # die with this process), so readiness resolves inline.
  let spawned = spawn_service(service, current.restarts, false)?
  let base = spawned.status

  # Record the child's kernel start time so a later status read can tell our
  # instance from an unrelated process that reuses the pid after ours exits.
  # (The scanner does not need this — it clears the pid on child exit.)
  let start_time_ms = if base.pid > 0 { pid_start_time(base.pid)? } else { 0 }

  let status: SavedStatus = {
    name: base.name,
    desired: base.desired,
    state: base.state,
    pid: base.pid,
    supervisor_pid: base.supervisor_pid,
    log: base.log,
    restarts: base.restarts,
    ready: base.ready,
    cgroup_path: base.cgroup_path,
    start_time_ms,
  }

  write_status(status)?
  return status
}

# True when a live scanner owns this run directory. Skipped under
# XSH_UNIX_DRY_RUN (pids are mocked there), so test-mode start/stop stay direct.
proc scanner_active() [fs, process, env, error] -> Result[Bool] {
  if env_enabled("XSH_UNIX_DRY_RUN") {
    return false
  }

  let marker = scanner_marker_path()?

  if ! marker.exists()? {
    return false
  }

  let raw = json.read(marker)?
  let pid: Int = json.get(raw, ["pid"], 0)
  return pid_alive(pid)
}

proc request_desired(name: Str, desired: Str) [fs, process, env, error] {
  let dir = inbox_dir()?
  dir.mkdir()?
  fs.write_atomic(fp"${dir.display()}/${name}", desired)?
  print f"${name} ${desired} queued"
}

proc start_service(name: Str) [fs, process, env, time, error] {
  # When a scanner owns the tree it is the source of truth: post a desired-state
  # request rather than spawning a second, unsupervised copy.
  if scanner_active()? {
    request_desired(name, "up")?
    return
  }

  let required = required_names(name)?
  var last = default_status(name)

  for item in plan_service_start(name)? {
    # `need` deps (and the service itself) are required: a failure aborts.
    # `uses`-only deps are optional: tolerate their start failure.
    if required.contains(item) {
      last = start_one_service(item)?
    } else {
      match start_one_service(item) {
        Ok(status) => last = status
        Err(_) => {}
      }
    }
  }

  print ${status_line(last)}
}

proc running_dependents(name: Str) [fs, process, env, error] -> Result[List[Str]] {
  let services = all_services()?
  var out: List[Str] = []

  for service in services {
    if service.name != name and required_dependencies(service).contains(name) {
      let status = read_status(service.name)?

      if status.state == "running" {
        out = out.push(service.name)
      }
    }
  }

  return out
}

proc stop_service(name: Str) [fs, process, env, time, error] {
  if scanner_active()? {
    request_desired(name, "down")?
    return
  }

  let dependents = running_dependents(name)?

  if dependents.len() > 0 {
    return Err(XinitError.Failed("xinit-deps", f"${name}: running dependents: ${dependents.join(", ")}"))
  }

  let current = read_status(name)?
  let service = load_service(name)?

  if run_stop_proc(service)? {} else if current.pid > 0 {
    unix.kill_process_group(current.pid, "TERM")?
    time.sleep(time.millis(service.stop_timeout_ms))?

    match unix.kill_process_group(current.pid, "KILL") {
      Ok(_) => {}
      Err(_) => {}
    }
  }

  let stopped = {
    name: current.name,
    desired: "down",
    state: "down",
    pid: 0,
    supervisor_pid: 0,
    log: current.log,
    restarts: current.restarts,
    ready: false,
    cgroup_path: "",
    start_time_ms: 0,
  }

  write_status(stopped)?
  print ${status_line(stopped)}
}

proc restart_service(name: Str) [fs, process, env, time, error] {
  # Under a scanner, restart is a single inbox action so the scanner does the
  # teardown-and-respawn itself; a direct stop+start here would race it and
  # spawn an unsupervised second copy.
  if scanner_active()? {
    request_desired(name, "restart")?
    return
  }

  stop_service(name)?
  let status = start_one_service(name)?
  print ${status_line(status)}
}

proc reload_service(name: Str) [fs, process, env, time, error] {
  if scanner_active()? {
    request_desired(name, "reload")?
    return
  }

  let current = read_status(name)?
  reload_unit(load_service(name)?, current.pid)?
  print ${status_line(current)}
}

proc show_status(name: Str) [fs, process, env, error] {
  var current = read_status(name)?

  match load_service(name) {
    Ok(loaded) => {
      current = read_status(loaded.name)?
      require_service_file(loaded.path)?
      let module_value = module.load(loaded.path)?.require(ServiceFile)?

      if module_value.has("status") {
        let detail = module_value.status()?

        if detail != "" {
          print f"${status_line(current)} ${detail}"
          return
        }
      }
    }
    Err(_) => {}
  }

  print ${status_line(current)}
}

proc show_logs(name: Str) [fs, env, error, io] {
  let current = log_path(name)?

  if current.exists()? {
    io.write_stdout(current.read_text()?)?
  }
}

proc check_service(...targets: List[Str]) [fs, process, env, error] {
  let services = if targets.len() == 0 { all_services()? } else { [load_service(targets[0])?] }
  check_service_graph(services)?
  let names = [service.name for service in services].join(" ")

  if names == "" {
    print "valid 0 services"
  } else {
    print f"valid ${services.len()} service(s): ${names}"
  }
}

pure escalate_delay(used_ms: Int, max_delay_ms: Int) -> Int {
  let doubled = used_ms * 2

  if max_delay_ms > 0 and doubled > max_delay_ms {
    return max_delay_ms
  }

  return doubled
}

pure unit_init(service: Service) -> ServiceUnit {
  return {
    service,
    desired: "up",
    state: "pending",
    pid: 0,
    restarts: 0,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  }
}

pure unit_state_label(unit: ServiceUnit) -> Str {
  if unit.state == "running" {
    return "running"
  }

  # Spawned but not yet ready (awaiting its notify byte).
  if unit.state == "starting" {
    return "starting"
  }

  # Running a finish() cleanup hook after the instance exited.
  if unit.state == "finishing" {
    return "finishing"
  }

  # A unit awaiting a backoff respawn is reported as "dead" so callers can tell
  # it apart from a clean stop; pending and stopped both read as "down".
  if unit.state == "dead" {
    return "dead"
  }

  return "down"
}

pure unit_saved_status(unit: ServiceUnit) -> SavedStatus {
  return {
    name: unit.service.name,
    desired: unit.desired,
    state: unit_state_label(unit),
    pid: if unit.pid > 0 { unit.pid } else { 0 },
    supervisor_pid: 0,
    log: unit.service.log,
    restarts: unit.restarts,
    ready: unit.state == "running" and unit.ready,
    cgroup_path: unit.cgroup_path,
    start_time_ms: 0,
  }
}

pure reverse_units(units: List[ServiceUnit]) -> List[ServiceUnit] {
  var out: List[ServiceUnit] = []
  var i = units.len() - 1

  while i >= 0 {
    out = out.push(units[i])
    i -= 1
  }

  return out
}

pure all_units_stopped(units: List[ServiceUnit]) -> Bool {
  for unit in units {
    if unit.state != "stopped" {
      return false
    }
  }

  return true
}

# Advance a `starting` unit toward `running`: ready once its notify byte arrives,
# or — if the ready timeout elapses — promoted to running but not ready, so a
# silent service does not wedge the scanner. The readiness fd is released either
# way.
proc advance_readiness(unit: ServiceUnit, now: Int) [fs, process, env, error] -> Result[ServiceUnit] {
  let ready = unit.notify_fd > 0 and unix.notify_ready(unit.notify_fd)?
  let timed_out = now - unit.started_at >= unit.service.ready_timeout_ms

  if ! ready and ! timed_out {
    return unit
  }

  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)?
  }

  let running: ServiceUnit = {
    service: unit.service,
    desired: unit.desired,
    state: "running",
    pid: unit.pid,
    restarts: unit.restarts,
    ready,
    cgroup_path: unit.cgroup_path,
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: unit.started_at,
    notify_fd: -1,
  }

  write_status(unit_saved_status(running))?
  return running
}

# Reconcile a unit toward its desired state. A `starting` unit advances toward
# ready; a wanted-up unit that is pending or dead and past its backoff gate is
# (re)spawned. Running units (and completed oneshots, pid 0 in state "running")
# return unchanged, so this is cheap to call on every poll.
pure unit_state_of(units: List[ServiceUnit], name: Str) -> Str {
  for unit in units {
    if unit.service.name == name {
      return unit.state
    }
  }

  return ""
}

# Whether a unit's ordering dependencies are satisfied enough for its first
# start. A `need` dep must be `running` (its startup, including readiness, has
# completed); `uses`/`after` deps may also be `stopped` (settled — optional or
# ordering-only, so a failed one does not block forever). Deps that are not
# scanned units (facilities, or absent) impose no gate. Respawns are not gated;
# only the initial pending -> running transition waits.
pure gate_satisfied(units: List[ServiceUnit], service: Service) -> Bool {
  for dep in service.need {
    let state = unit_state_of(units, dep)

    if state != "" and state != "running" {
      return false
    }
  }

  for dep in service.uses.extend(service.after) {
    let state = unit_state_of(units, dep)

    if state != "" and state != "running" and state != "stopped" {
      return false
    }
  }

  return true
}

# True for a pending unit that cannot start yet because a dependency is still
# coming up. Used to gate the initial start and to avoid spinning the scanner
# while it waits (the dependency's own transitions drive the wakeups).
pure unit_blocked(units: List[ServiceUnit], unit: ServiceUnit) -> Bool {
  return unit.desired == "up" and unit.state == "pending" and ! gate_satisfied(units, unit.service)
}

proc reconcile_one(
  unit: ServiceUnit,
  units: List[ServiceUnit],
  now: Int,
) [fs, process, env, time, error] -> Result[ServiceUnit] {
  if unit.state == "starting" {
    return advance_readiness(unit, now)?
  }

  if unit.desired != "up" {
    return unit
  }

  if unit.state != "pending" and unit.state != "dead" {
    return unit
  }

  # Dependency-ordered readiness gating: an initial start waits until its
  # ordering deps are up. Respawns (state "dead") are not gated.
  if unit.state == "pending" and ! gate_satisfied(units, unit.service) {
    return unit
  }

  # Pending/dead units hold pid 0, so this is the shared backoff gate.
  if ! spawn_due(unit.pid, now, unit.next_ms) {
    return unit
  }

  let restarts = if unit.state == "dead" { unit.restarts + 1 } else { unit.restarts }
  let spawned = spawn_service(unit.service, restarts, true)?
  let state = if spawned.notify_fd > 0 { "starting" } else { "running" }

  let started: ServiceUnit = {
    service: unit.service,
    desired: "up",
    state,
    pid: spawned.status.pid,
    restarts,
    ready: spawned.status.ready,
    cgroup_path: spawned.status.cgroup_path,
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: now,
    notify_fd: spawned.notify_fd,
  }

  write_status(unit_saved_status(started))?
  return started
}

# Reconcile every unit against a single start-of-pass snapshot, so gating reads
# consistent dependency states regardless of iteration order.
proc reconcile_all(units: List[ServiceUnit], now: Int) [fs, process, env, time, error] -> Result[List[ServiceUnit]] {
  return [reconcile_one(unit, units, now)? for unit in units]
}

# Apply the death of a unit's child: either schedule a backoff respawn (the
# `next_ms` gate, so reconcile relaunches on a later pass without blocking the
# scanner) or, when the restart policy declines, mark the unit stopped. Backoff
# resets to the base delay after an instance stayed up at least stable_after_ms.
pure finishing_unit(unit: ServiceUnit) -> ServiceUnit {
  return {
    service: unit.service,
    desired: unit.desired,
    state: "finishing",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: unit.started_at,
    notify_fd: -1,
  }
}

# Run a service's finish() cleanup hook after its instance has exited (on stop
# or crash). While the hook runs the unit is reported as "finishing". A service
# with no finish() hook is left untouched.
proc run_finish(unit: ServiceUnit) [fs, process, env, error] {
  require_service_file(unit.service.path)?
  let loaded = module.load(unit.service.path)?.require(ServiceFile)?

  if loaded.has("finish") {
    write_status(unit_saved_status(finishing_unit(unit)))?
    loaded.finish()?
  }
}

proc mark_unit_dead(
  unit: ServiceUnit,
  child_status: Status,
  now: Int,
) [fs, process, env, error] -> Result[ServiceUnit] {
  # The child is already gone; release any readiness fd it held, then run the
  # finish() cleanup hook before deciding the unit's next state.
  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)?
  }

  run_finish(unit)?

  let should_restart = unit.service.restart_mode == "always" or unit.service.restart_mode == "on_failure" and ! child_status.exited_with(
    0,
  )

  if ! should_restart {
    let stopped: ServiceUnit = {
      service: unit.service,
      desired: "down",
      state: "stopped",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    }

    write_status(unit_saved_status(stopped))?
    return stopped
  }

  let reset = now - unit.started_at >= unit.service.stable_after_ms
  let delay = if reset { unit.service.delay_ms } else { unit.current_delay }

  let dead: ServiceUnit = {
    service: unit.service,
    desired: "up",
    state: "dead",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: now + delay,
    current_delay: escalate_delay(delay, unit.service.max_delay_ms),
    started_at: unit.started_at,
    notify_fd: -1,
  }

  write_status(unit_saved_status(dead))?
  return dead
}

proc mark_children_dead(
  units: List[ServiceUnit],
  child_pid: Int,
  child_status: Status,
  now: Int,
) [fs, process, env, error] -> Result[List[ServiceUnit]] {
  var out: List[ServiceUnit] = []

  for unit in units {
    if unit.pid > 0 and unit.pid == child_pid and (unit.state == "running" or unit.state == "starting") {
      out = out.push(mark_unit_dead(unit, child_status, now)?)
    } else {
      out = out.push(unit)
    }
  }

  return out
}

# Tear down a unit's running instance: run its `stop()` hook if it has one,
# otherwise TERM then KILL the process group. No status write; callers decide
# the resulting unit state.
proc kill_unit(unit: ServiceUnit) [fs, process, env, time, error] {
  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)?
  }

  if run_stop_proc(unit.service)? {} else if unit.pid > 0 {
    unix.kill_process_group(unit.pid, "TERM")?
    time.sleep(time.millis(unit.service.stop_timeout_ms))?

    match unix.kill_process_group(unit.pid, "KILL") {
      Ok(_) => {}
      Err(_) => {}
    }
  }

  # Cleanup hook after the instance is down.
  run_finish(unit)?
}

# Stop a unit directly, with no dependency-refusal check (that belongs to the
# operator-facing `stop` command, not to scanner-driven shutdown).
proc stop_unit(unit: ServiceUnit) [fs, process, env, time, error] -> Result[ServiceUnit] {
  kill_unit(unit)?

  let stopped: ServiceUnit = {
    service: unit.service,
    desired: "down",
    state: "stopped",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: unit.service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  }

  write_status(unit_saved_status(stopped))?
  return stopped
}

proc shutdown_all(units: List[ServiceUnit]) [fs, process, env, time, error] -> Result[List[ServiceUnit]] {
  let reversed = [stop_unit(unit)? for unit in reverse_units(units)]
  return reverse_units(reversed)
}

proc write_scanner_marker() [fs, process, env, error] {
  let dir = run_dir()?
  dir.mkdir()?
  json.write(scanner_marker_path()?, {pid: process.current_pid()?})?
}

# Apply one desired-state request to a single unit. "down" stops a running unit
# and parks it; "up" makes it schedulable again (reconcile spawns it on the next
# pass). A request for a different unit name is a no-op.
proc apply_one(unit: ServiceUnit, name: Str, desired: Str) [fs, process, env, time, error] -> Result[ServiceUnit] {
  if unit.service.name != name {
    return unit
  }

  if desired == "down" {
    if unit.pid > 0 or unit.state == "running" or unit.state == "starting" {
      return stop_unit(unit)?
    }

    return {
      service: unit.service,
      desired: "down",
      state: "stopped",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    }
  }

  # "reload" refreshes a running unit in place (reload() hook or SIGHUP) without
  # changing its state.
  if desired == "reload" {
    if unit.state == "running" or unit.state == "starting" {
      reload_unit(unit.service, unit.pid)?
    }

    return unit
  }

  # "restart" tears down the current instance and re-arms the unit for an
  # immediate respawn on the next reconcile pass. A desired-state slot cannot
  # hold a transient, so restart is expressed as its own inbox action.
  if desired == "restart" {
    kill_unit(unit)?

    let restarted: ServiceUnit = {
      service: unit.service,
      desired: "up",
      state: "pending",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    }

    write_status(unit_saved_status(restarted))?
    return restarted
  }

  # "up": an already-active unit (running or starting) is left as-is; an
  # idle/stopped one is re-armed so reconcile spawns it on the next pass.
  if unit.state == "running" or unit.state == "starting" {
    return unit
  }

  return {
    service: unit.service,
    desired: "up",
    state: "pending",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: unit.service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  }
}

proc apply_request(
  units: List[ServiceUnit],
  name: Str,
  desired: Str,
) [fs, process, env, time, error] -> Result[List[ServiceUnit]] {
  return [apply_one(unit, name, desired)? for unit in units]
}

# Drain the control inbox: each request file is named for a service and holds
# "up" or "down". This is the supervisor side of the control plane — operators
# (and `start`/`stop` when a scanner owns the tree) post desired-state requests
# rather than signalling a pid, so the scanner stays the source of truth.
proc drain_inbox(units: List[ServiceUnit]) [fs, process, env, time, error] -> Result[List[ServiceUnit]] {
  let dir = inbox_dir()?

  if ! dir.exists()? {
    return units
  }

  var out = units

  for entry in fs.children(dir)?
    |> where .kind == "file"
    |> sort-by .name {
    let desired = entry.path.read_text()?.trim()

    if desired == "up" or desired == "down" or desired == "restart" or desired == "reload" {
      out = apply_request(out, entry.name, desired)?
    }

    fs.remove(entry.path)?
  }

  return out
}

# The unified scanner: hold a set of units and reconcile them toward their
# desired state on every wakeup. `wait_pid1_event` returns a `poll` event within
# ~100ms even when idle, so the loop re-checks backoff gates without a dedicated
# timer. This is the single supervision mechanism behind both `supervise` (one
# unit) and `scan` (a whole dependency tree).
# A `starting` unit has no notify_fd event to wait on, so the scanner polls its
# readiness on this cadence rather than spinning (a zero wait would busy-loop a
# notify service's whole startup at 100% CPU).
pure readiness_poll_ms() -> Int {
  return 100
}

pure due_ms(unit: ServiceUnit, now: Int) -> Int {
  let due = unit.next_ms - now

  if due < 0 {
    return 0
  }

  return due
}

# How long the scanner may block before it must reconcile again: the soonest
# pending/dead unit's backoff gate, the readiness poll cadence for starting
# units, else an hour. wait_pid1_event still wakes within ~100ms for signals and
# children, so the long ceiling only bounds idle sleeps.
pure next_wait_ms(units: List[ServiceUnit], now: Int) -> Int {
  var soonest = -1

  for unit in units {
    # A pending unit blocked on a dependency is not "due" — its wakeup comes from
    # the dependency's own transition (a starting poll, a respawn deadline, or a
    # child exit), so skipping it here keeps the scanner from spinning.
    let candidate = if unit.state == "starting" {
      readiness_poll_ms()
    } else if unit.desired != "up" {
      -1
    } else if unit.state == "dead" {
      due_ms(unit, now)
    } else if unit.state == "pending" and ! unit_blocked(units, unit) {
      due_ms(unit, now)
    } else {
      -1
    }

    if candidate >= 0 and (soonest < 0 or candidate < soonest) {
      soonest = candidate
    }
  }

  if soonest < 0 {
    return 3600000
  }

  return soonest
}

# Bound the logs of running services: a long-lived instance that never restarts
# would otherwise grow `current` without limit. Copy-truncates over the cap each
# pass; the rotate-on-spawn path covers services that crash and restart.
proc enforce_log_caps(units: List[ServiceUnit]) [fs, env, error] {
  for unit in units {
    if unit.state == "running" and unit.service.log == "append" {
      maybe_rotate_log(unit.service.name, unit.service.log_max_size, unit.service.log_keep)?
    }
  }
}

proc scan_units(names: List[Str]) [fs, process, env, time, error] {
  unix.pid1_setup(["HUP", "TERM", "INT"], subreaper: true, allow_non_pid1: true)?
  var units = [unit_init(load_service(name)?) for name in names]
  var remaining = env_int("XINIT_TEST_MAX_EVENTS", -1)?
  var shutting_down = false
  write_scanner_marker()?

  while true {
    if ! shutting_down {
      units = drain_inbox(units)?
    }

    units = reconcile_all(units, time.now())?
    enforce_log_caps(units)?

    if shutting_down and all_units_stopped(units) {
      return
    }

    if remaining == 0 {
      return
    }

    let event = unix.wait_pid1_event(timeout: time.millis(next_wait_ms(units, time.now())))?

    if remaining > 0 {
      remaining -= 1
    }

    if event.kind == "signal" and (event.signal == "TERM" or event.signal == "INT") {
      units = shutdown_all(units)?
      shutting_down = true
    } else if event.kind == "children" {
      let now = time.now()

      for child in event.children {
        units = mark_children_dead(units, child.pid, child.status, now)?
      }
    }
  }
}

proc supervise_service(name: Str) [fs, process, env, time, error] {
  scan_units([name])?
}

proc scan_command(target: Str) [fs, process, env, time, error] {
  let names = match load_service(target) { Ok(_) => plan_service_start(target)?, Err(_) => plan_target_start(target)? }
  scan_units(names)?
}

proc boot_target(target: Str) [fs, process, env, time, error] {
  var last = default_status(target)

  for item in plan_target_start(target)? {
    last = start_one_service(item)?
  }

  print ${status_line(last)}
}

proc list_services() [fs, process, env, error] {
  for service in all_services()? {
    let status = read_status(service.name)?
    print f"${service.name} ${service.kind} targets=${service.targets.join(",")} state=${status.state} ready=${status.ready}"
  }
}

proc graph_target(target: Str) [fs, process, env, error] {
  let plan = plan_target_start(target)?

  for item in plan {
    let service = load_service(item)?
    let deps = dependency_edges(service).join(",")
    print f"${item}: deps=${deps}"
  }
}

proc graph_service(name: Str) [fs, process, env, error] {
  for item in plan_service_start(name)? {
    let service = load_service(item)?
    let deps = dependency_edges(service).join(",")
    print f"${item}: deps=${deps}"
  }
}

proc control(argv: List[Str]) [fs, process, env, time, error, io] {
  if argv.len() != 2 {
    return Err(
      XinitError.Failed("xinit-control", "usage: xinit <start|stop|restart|reload|status|logs|supervise> SERVICE"),
    )
  }

  let verb = argv[0]
  let name = argv[1]

  if verb == "start" or verb == "up" {
    start_service(name)?
  } else if verb == "stop" or verb == "down" {
    stop_service(name)?
  } else if verb == "restart" {
    restart_service(name)?
  } else if verb == "reload" {
    reload_service(name)?
  } else if verb == "status" {
    show_status(name)?
  } else if verb == "logs" {
    show_logs(name)?
  } else if verb == "supervise" {
    supervise_service(name)?
  } else {
    return Err(
      XinitError.Failed("xinit-control", "usage: xinit <start|stop|restart|reload|status|logs|supervise> SERVICE"),
    )
  }
}

proc main(...argv: List[Str]) [fs, process, env, time, error, io] {
  if argv.len() == 0 {
    run_pid1(Path.parse(env_value("XSH_INIT_INITTAB", "/etc/inittab"))?)?
    return
  }

  if argv[0] == "--help" or argv[0] == "-h" {
    io.write_stdout(usage_text())?
  } else if argv[0] == "boot" {
    if argv.len() > 2 {
      return Err(XinitError.Failed("xinit-control", "usage: xinit boot [TARGET]"))
    }

    boot_target(argv.get(1, "boot"))?
  } else if argv[0] == "scan" {
    if argv.len() > 2 {
      return Err(XinitError.Failed("xinit-control", "usage: xinit scan [SERVICE|TARGET]"))
    }

    scan_command(argv.get(1, "boot"))?
  } else if argv[0] == "list" {
    if argv.len() != 1 {
      return Err(XinitError.Failed("xinit-control", "usage: xinit list"))
    }

    list_services()?
  } else if argv[0] == "graph" {
    if argv.len() > 2 {
      return Err(XinitError.Failed("xinit-control", "usage: xinit graph [SERVICE|TARGET]"))
    }

    let target = argv.get(1, "boot")

    match load_service(target) {
      Ok(_) => graph_service(target)?
      Err(_) => graph_target(target)?
    }
  } else if argv[0] == "start" or argv[0] == "up" or argv[0] == "stop" or argv[0] == "down" or argv[0] == "restart" or argv[0] == "reload" or argv[0] == "status" or argv[0] == "logs" or argv[0] == "supervise" {
    control(argv)?
  } else if argv[0] == "check" {
    if argv.len() > 2 {
      return Err(XinitError.Failed("xinit-control", "usage: xinit check [SERVICE|PATH]"))
    }

    if argv.len() == 1 {
      check_service()?
    } else {
      check_service(argv[1])?
    }
  } else if argv[0].starts_with("-") {
    return Err(XinitError.Failed("xinit-control", f"unknown option '${argv[0]}'"))
  } else if argv.len() == 1 {
    run_pid1(Path.parse(argv[0])?)?
  } else {
    return Err(XinitError.Failed("xinit-control", "usage: xinit [start|stop|status|logs|supervise SERVICE]"))
  }
}

main(@args)?
