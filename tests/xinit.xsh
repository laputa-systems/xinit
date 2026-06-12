pure xsh_bin() -> Path {
  return ../xsh/target/debug/xsh
}

pure xinit_script() -> Path {
  return p"xinit.xsh"
}

proc write_demo_service(path_value: Path, command: Str, restart_mode: Str, log_none: Bool, cpu_max: Int) [fs, error] {
  var extra = ""

  if log_none {
    extra = f"""${extra}  logging: "off",
"""
  }

  if cpu_max > 0 {
    extra = f"""${extra}  resources: {cpu_max: ${cpu_max}},
"""
  }

  path_value.write(f"""export let service = {
  name: "demo",
  kind: "longrun",
  command: ${command},
  restart: {mode: "${restart_mode}", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
  targets: ["boot"],
${extra}}
""")?
}

proc write_named_service(
  path_value: Path,
  name: Str,
  command: Str,
  targets: List[Str],
  deps: Str,
  extra: Str = "",
) [fs, error] {
  path_value.write(f"""export let service = {
  name: "${name}",
  kind: "longrun",
  command: ${command},
  restart: {mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
  targets: ${json.encode(targets)?},
  dependencies: {${deps}},
${extra}}
""")?
}

proc assert_failed_with(status: Status, stderr: Path, expected: Str) [fs, error] {
  test.ok(! status.ok, "expected command to fail")?
  test.contains(stderr.read_text()?, expected)?
}

proc test_inittab_parsing_and_lifecycle(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "inittab")?
  let valid = fp"${root}/valid.inittab"
  let unsupported = fp"${root}/unsupported.inittab"
  let shell_syntax = fp"${root}/shell-syntax.inittab"
  let err = fp"${root}/err"

  valid.write("""# comment

::sysinit:/bin/echo "boot: ok"
::wait:/bin/echo "wait: ok"
::once:/bin/echo "once: ok"
::restart:/bin/echo restart
::shutdown:/bin/echo "down: ok"
ttyS0::respawn:/bin/echo "login: ttyS0"
ttyS1::poweroff:/bin/echo "login: ttyS1"
""")?

  unsupported.write("""::bogus:/bin/echo nope
""")?

  shell_syntax.write("""::sysinit:/bin/echo ok && /bin/echo no
""")?

  let output = run.text XINIT_TEST_ALLOW_NON_PID1=1 XSH_INIT_TEST_MAX_RESPAWNS=1 XSH_LINUX_DRY_RUN=1 XSH_LINUX_DRY_RUN_SIGNAL=TERM XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_SIGNAL=TERM (xsh_bin()) (xinit_script()) -- (valid.display()) ?

  test.eq(
    output,
    """boot: ok
wait: ok
down: ok
""",
  )?

  let unsupported_status = run.status XINIT_TEST_ALLOW_NON_PID1=1 XSH_INIT_TEST_MAX_RESPAWNS=1 XSH_LINUX_DRY_RUN=1 XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- (unsupported.display()) 2> $err
  assert_failed_with(unsupported_status, err, "unsupported action 'bogus'")?
  let shell_status = run.status XINIT_TEST_ALLOW_NON_PID1=1 XSH_INIT_TEST_MAX_RESPAWNS=1 XSH_LINUX_DRY_RUN=1 XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- (shell_syntax.display()) 2> $err
  assert_failed_with(shell_status, err, "shell syntax")?
}

proc test_wait_once_respawn_and_poweroff(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "lifecycle")?
  let inittab = fp"${root}/inittab"
  let unix_log = fp"${root}/unix.jsonl"
  let linux_log = fp"${root}/linux.jsonl"

  inittab.write("""::sysinit:/bin/echo boot
::wait:/bin/echo wait
::once:/usr/bin/once-service
::respawn:/usr/bin/respawn-service
""")?

  let output = run.text XINIT_TEST_ALLOW_NON_PID1=1 XSH_INIT_TEST_EXIT_WHEN_IDLE=1 XSH_INIT_TEST_MAX_RESPAWNS=1 XSH_INIT_TEST_RESPAWN_DELAY_MS=1 XSH_LINUX_DRY_RUN=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1001 (xsh_bin()) (xinit_script()) -- (inittab.display()) ?

  test.eq(
    output,
    """boot
wait
""",
  )?

  let unix_log_text = unix_log.read_text()?
  test.contains(unix_log_text, "once-service")?
  test.contains(unix_log_text, "respawn-service")?
  let poweroff_inittab = fp"${root}/poweroff.inittab"

  poweroff_inittab.write("""::sysinit:/bin/echo boot
ttyAMA0::poweroff:/usr/local/bin/xshi --no-config
""")?

  let poweroff_output = run.text XINIT_TEST_ALLOW_NON_PID1=1 XSH_LINUX_DRY_RUN=1 XSH_LINUX_DRY_RUN_LOG=(linux_log.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1000 (xsh_bin()) (xinit_script()) -- (poweroff_inittab.display()) ?

  test.eq(
    poweroff_output,
    """boot
""",
  )?

  test.contains(linux_log.read_text()?, "\"op\":\"poweroff\"")?
}

proc test_fast_shutdown_uses_owned_process_groups(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "fast-shutdown")?
  let inittab = fp"${root}/inittab"
  let unix_log = fp"${root}/unix.jsonl"
  let linux_log = fp"${root}/linux.jsonl"

  inittab.write("""::sysinit:/bin/echo boot
::shutdown:/bin/echo down
::respawn:/usr/bin/daemon
ttyAMA0::poweroff:/usr/local/bin/xshi --no-config
""")?

  let output = run.text XINIT_TEST_ALLOW_NON_PID1=1 XSH_INIT_FAST_SHUTDOWN=1 XSH_INIT_FINAL_CLEANUP=0 XSH_LINUX_DRY_RUN=1 XSH_LINUX_DRY_RUN_LOG=(linux_log.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1001 (xsh_bin()) (xinit_script()) -- (inittab.display()) ?

  test.eq(
    output,
    """boot
down
""",
  )?

  let unix_log_text = unix_log.read_text()?
  test.contains(unix_log_text, "\"op\":\"pid1_shutdown\"")?
  test.contains(unix_log_text, "\"groups\":\"1000\"")?
  test.contains(unix_log_text, "\"term_timeout_ms\":\"0\"")?
  let linux_log_text = linux_log.read_text()?
  test.ok(! ("\"op\":\"kill_all\"" in linux_log_text))?
  test.contains(linux_log_text, "\"op\":\"poweroff\"")?
}

proc test_service_start_status_stop_and_check(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "service")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()
  write_demo_service(fp"${service_dir}/demo.xsh", "process.command_argv(\"service\", [\"service\"])", "never", false, 0)?
  let started = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) (xsh_bin()) (xinit_script()) -- "start" "demo" ?

  test.eq(
    started,
    """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let state = fp"${run_dir}/demo.json".read_text()?
  test.contains(state, "\"state\":\"running\"")?
  test.contains(state, "\"log\":\"append\"")?
  test.ok(! ("log_pid" in state))?
  let log_text = unix_log.read_text()?
  test.contains(log_text, "spawn_process_group")?
  test.contains(log_text, "log_path")?
  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let stopped = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) (xsh_bin()) (xinit_script()) -- "stop" "demo" ?

  test.eq(
    stopped,
    """demo down pid=0 ready=false log=append desired=down restarts=0
""",
  )?

  let checked = run.text (xsh_bin()) (xinit_script()) -- check (fp"${service_dir}/demo.xsh".display()) ?

  test.eq(
    checked,
    """valid 1 service(s): demo
""",
  )?
}

proc test_check_reports_errors(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "check-errors")?
  let bad = fp"${root}/bad.xsh"
  let missing = fp"${root}/missing.xsh"
  let err = fp"${root}/err"

  bad.write("""pure bad(xs: List[Str]) -> List[Str] {
  xs = ["service"]
  return xs
}

export let service = {
  name: "bad",
  command: process.command_argv("service", bad([])),
}
""")?

  let bad_status = run.status (xsh_bin()) (xinit_script()) -- check (bad.display()) 2> $err
  assert_failed_with(bad_status, err, "module-check")?
  test.contains(err.read_text()?, "check.pure-assignment")?
  test.contains(err.read_text()?, bad.display())?
  let missing_status = run.status (xsh_bin()) (xinit_script()) -- check (missing.display()) 2> $err
  assert_failed_with(missing_status, err, "xinit-service")?
  test.contains(err.read_text()?, "failed to read service file")?
  test.contains(err.read_text()?, missing.display())?
  let old_status = run.status (xsh_bin()) (xinit_script()) -- validate demo 2> $err
  assert_failed_with(old_status, err, "xinit-control")?
  test.contains(err.read_text()?, "usage: xinit")?
}

proc test_dependency_planning_boot_list_graph_and_stop_refusal(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "deps")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  let err = fp"${root}/err"
  service_dir.mkdir()

  write_named_service(
    fp"${service_dir}/logger.xsh",
    "logger",
    "process.command_argv(\"logger\", [\"logger\"])",
    ["boot"],
    "",
  )?

  write_named_service(
    fp"${service_dir}/firewall.xsh",
    "firewall",
    "process.command_argv(\"firewall\", [\"firewall\"])",
    ["boot"],
    "before: [\"net\"]",
  )?

  write_named_service(
    fp"${service_dir}/net.xsh",
    "net",
    "process.command_argv(\"net\", [\"net\"])",
    ["boot"],
    "need: [\"logger\"], after: [\"firewall\"]",
  )?

  write_named_service(
    fp"${service_dir}/app.xsh",
    "app",
    "process.command_argv(\"app\", [\"app\"])",
    ["boot"],
    "need: [\"net\"], uses: [\"logger\"]",
  )?

  let graph = run.text XINIT_SERVICE_DIR=(service_dir.display()) (xsh_bin()) (xinit_script()) -- graph app ?
  test.contains(graph, "logger: deps=")?
  test.contains(graph, "firewall: deps=")?
  test.contains(graph, "net: deps=logger,firewall")?
  test.contains(graph, "app: deps=net,logger")?
  let boot = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) (xsh_bin()) (xinit_script()) -- boot ?
  test.contains(boot, "app running")?
  test.ok(fp"${run_dir}/logger.json".exists()?)?
  test.ok(fp"${run_dir}/firewall.json".exists()?)?
  test.ok(fp"${run_dir}/net.json".exists()?)?
  test.ok(fp"${run_dir}/app.json".exists()?)?
  let listed = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- list ?
  test.contains(listed, "app longrun targets=boot state=running ready=true")?
  test.contains(listed, "net longrun targets=boot state=running ready=true")?
  let stop_net = run.status XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- stop net 2> $err
  assert_failed_with(stop_net, err, "running dependents: app")?
}

proc test_ready_and_status_hooks(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "ready")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"${service_dir}/demo.xsh",
    """export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {mode: "never"},
}

export proc ready() [fs, process, env, time, error] -> Result[Bool] {
  return true
}

export proc status() [fs, process, env, error] -> Result[Str] {
  return "detail=ok"
}
""",
  )?

  let started = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- start demo ?

  test.eq(
    started,
    """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let status = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1000 ready=true log=append desired=up restarts=0 detail=ok
""",
  )?
}

proc test_append_logs_and_log_none(ctx: TestContext) [fs, process, time, error] {
  let root = test.temp_dir(ctx, name: "logs")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  service_dir.mkdir()

  write_demo_service(
    fp"${service_dir}/demo.xsh",
    "process.command_argv(\"/bin/sh\", [\"-c\", \"printf service-out; printf service-err >&2\"])",
    "never",
    false,
    0,
  )?

  let started = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) (xsh_bin()) (xinit_script()) -- "start" "demo" ?
  test.contains(started, "demo running")?
  time.sleep(100ms)?
  let log_text = fp"${log_root}/demo/current".read_text()?
  test.contains(log_text, "service-out")?
  test.contains(log_text, "service-err")?
  let logs = run.text XINIT_LOG_ROOT=(log_root.display()) (xsh_bin()) (xinit_script()) -- logs demo ?
  test.eq(logs, log_text)?
  let none_service_dir = fp"${root}/none-services"
  let none_run_dir = fp"${root}/none-run"
  let none_log_root = fp"${root}/none-logs"
  none_service_dir.mkdir()

  write_demo_service(
    fp"${none_service_dir}/demo.xsh",
    "process.command_argv(\"/bin/true\", [\"true\"])",
    "never",
    true,
    0,
  )?

  let none_started = run.text XINIT_SERVICE_DIR=(none_service_dir.display()) XINIT_RUN_DIR=(none_run_dir.display()) XINIT_LOG_ROOT=(none_log_root.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- "start" "demo" ?

  test.eq(
    none_started,
    """demo running pid=1000 ready=true log=none desired=up restarts=0
""",
  )?

  test.ok(! fp"${none_log_root}/demo/current".exists()?)?
}

proc test_append_log_rotates_over_size_cap(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "rotate")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"${service_dir}/demo.xsh",
    """export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("/bin/true", ["true"]),
  log: {mode: "append", max_size: 10, keep: 2},
  restart: {mode: "never"},
}
""",
  )?

  # Pre-fill `current` past the cap; the next start must rotate it to current.1
  # and begin a fresh `current`.
  fp"${log_root}/demo".mkdir()?
  fp"${log_root}/demo/current".write("0123456789AB")?
  let _ = run.status XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) (xsh_bin()) (xinit_script()) -- start demo
  test.eq(fp"${log_root}/demo/current.1".read_text()?, "0123456789AB")?
  test.eq(fp"${log_root}/demo/current".read_text()?, "")?
}

proc test_status_compat_cgroup_and_log_open_failure(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "status")?
  let run_dir = fp"${root}/run"
  run_dir.mkdir()

  fp"${run_dir}/demo.json".write(
    "{\"name\":\"demo\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"log_pid\":1001,\"restarts\":0}",
  )?

  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let service_dir = fp"${root}/services"
  let cgroup_run_dir = fp"${root}/cgroup-run"
  let log_root = fp"${root}/logs"
  service_dir.mkdir()

  write_demo_service(
    fp"${service_dir}/demo.xsh",
    "process.command_argv(\"service\", [\"service\"])",
    "never",
    false,
    80,
  )?

  let cgroup = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(cgroup_run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- "start" "demo" ?

  test.eq(
    cgroup,
    """demo running pid=1000 ready=true log=append desired=up restarts=0 cgroup=dry-run:/xinit/demo
""",
  )?

  test.contains(fp"${cgroup_run_dir}/demo.json".read_text()?, "\"cgroup_path\":\"dry-run:/xinit/demo\"")?
  let blocker = fp"${root}/not-a-dir"
  blocker.write("file")?
  let err = fp"${root}/err"
  let failed = run.status XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(fp"${root}/failed-run".display()) XINIT_LOG_ROOT=(blocker.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- "start" "demo" 2> $err
  assert_failed_with(failed, err, "xinit-log")?
  test.ok(! fp"${root}/failed-run/demo.json".exists()?)?
}

proc test_idempotent_start_and_supervise_restart(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "restart")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()
  write_demo_service(fp"${service_dir}/demo.xsh", "process.command_argv(\"service\", [\"service\"])", "never", false, 0)?

  for _ in [0, 1] {
    let output = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) (xsh_bin()) (xinit_script()) -- "start" "demo" ?

    test.eq(
      output,
      """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
    )?
  }

  test.eq(unix_log.read_text()?.split("spawn_process_group").len(), 2)?
  let supervise_service_dir = fp"${root}/supervise-services"
  let supervise_run_dir = fp"${root}/supervise-run"
  let supervise_log_root = fp"${root}/supervise-logs"
  let supervise_unix_log = fp"${root}/supervise-unix.jsonl"
  supervise_service_dir.mkdir()

  write_demo_service(
    fp"${supervise_service_dir}/demo.xsh",
    "process.command_argv(\"service\", [\"service\"])",
    "always",
    false,
    0,
  )?

  let supervise = run.text XINIT_SERVICE_DIR=(supervise_service_dir.display()) XINIT_RUN_DIR=(supervise_run_dir.display()) XINIT_LOG_ROOT=(supervise_log_root.display()) XINIT_TEST_MAX_EVENTS=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(supervise_unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1000 XSH_UNIX_DRY_RUN_EXIT_CODE=1 (xsh_bin()) (xinit_script()) -- "supervise" "demo" ?
  test.eq(supervise, "")?
  let status = run.text XINIT_RUN_DIR=(supervise_run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1001 ready=true log=append desired=up restarts=1
""",
  )?

  test.eq(supervise_unix_log.read_text()?.split("spawn_process_group").len(), 3)?
}

proc test_status_reconciles_stale_pid(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "liveness")?
  let run_dir = fp"${root}/run"
  run_dir.mkdir()

  # Use this test process's own pid as a known-live, same-user pid: the status
  # subprocess can signal it with signal 0, so a real (non-dry-run) status read
  # must preserve the running state rather than reconcile it away.
  let self_pid = process.current_pid()?

  fp"${run_dir}/alive.json".write(
    f"{\"name\":\"alive\",\"desired\":\"up\",\"state\":\"running\",\"pid\":${self_pid},\"restarts\":0}",
  )?

  let alive = run.text XINIT_RUN_DIR=(run_dir.display()) (xsh_bin()) (xinit_script()) -- status alive ?

  test.eq(
    alive,
    f"""alive running pid=${self_pid} ready=true log=append desired=up restarts=0
""",
  )?

  # A pid far above any real process id is gone, so a saved "running" state must
  # reconcile to "dead" with the tracked pid cleared. This is what stops `status`
  # reporting a phantom and stops `stop` signalling a recycled pid.
  fp"${run_dir}/gone.json".write(
    "{\"name\":\"gone\",\"desired\":\"up\",\"state\":\"running\",\"pid\":2147480000,\"restarts\":2}",
  )?

  let gone = run.text XINIT_RUN_DIR=(run_dir.display()) (xsh_bin()) (xinit_script()) -- status gone ?

  test.eq(
    gone,
    """gone dead pid=0 ready=false log=append desired=up restarts=2
""",
  )?
}

proc test_status_detects_recycled_pid(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "identity")?
  let run_dir = fp"${root}/run"
  run_dir.mkdir()

  # This test process is a known-live, same-user pid; find its kernel start time.
  let self_pid = process.current_pid()?
  var self_start = 0

  for entry in process.list()? {
    if entry.pid == self_pid {
      self_start = entry.start_time_ms
    }
  }

  # A matching recorded start time means the pid is still our instance: running.
  fp"${run_dir}/ours.json".write(
    f"{\"name\":\"ours\",\"desired\":\"up\",\"state\":\"running\",\"pid\":${self_pid},\"start_time_ms\":${self_start},\"restarts\":0}",
  )?

  let ours = run.text XINIT_RUN_DIR=(run_dir.display()) (xsh_bin()) (xinit_script()) -- status ours ?

  test.eq(
    ours,
    f"""ours running pid=${self_pid} ready=true log=append desired=up restarts=0
""",
  )?

  # A non-matching recorded start time means the pid was recycled into a
  # different process after ours exited, so the saved state reconciles to dead.
  fp"${run_dir}/recycled.json".write(
    f"{\"name\":\"recycled\",\"desired\":\"up\",\"state\":\"running\",\"pid\":${self_pid},\"start_time_ms\":1,\"restarts\":0}",
  )?

  let recycled = run.text XINIT_RUN_DIR=(run_dir.display()) (xsh_bin()) (xinit_script()) -- status recycled ?

  test.eq(
    recycled,
    """recycled dead pid=0 ready=false log=append desired=up restarts=0
""",
  )?
}

proc test_supervise_defers_restart_with_backoff(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "backoff")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()

  # A nonzero base delay must defer the respawn behind a next_ms gate rather
  # than block the scanner: after the crash event the unit is scheduled ("dead"),
  # not yet relaunched, and only one spawn has happened so far. This is the
  # non-blocking backoff the scanner model gives us (delay_ms: 0 relaunches
  # immediately, exercised by the idempotent-restart test).
  fs.write(
    fp"${service_dir}/demo.xsh",
    """export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("service", ["service"]),
  restart: {mode: "always", delay_ms: 30000, max_delay_ms: 30000, stable_after_ms: 100000},
}
""",
  )?

  let supervise = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1000 XSH_UNIX_DRY_RUN_EXIT_CODE=1 (xsh_bin()) (xinit_script()) -- "supervise" "demo" ?
  test.eq(supervise, "")?
  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo dead pid=0 ready=false log=append desired=up restarts=0
""",
  )?

  test.eq(unix_log.read_text()?.split("spawn_process_group").len(), 2)?
}

proc test_scan_respawns_one_unit_independently(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "scan")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()

  # Two independent (dependency-free) services in one boot target. Dry-run spawn
  # pids increment per call, so the bring-up gives logger=1000, worker=1001.
  # Killing worker (pid 1001) must respawn only worker (-> 1002) while logger
  # stays untouched, demonstrating independent per-unit supervision.
  fs.write(
    fp"${service_dir}/logger.xsh",
    """export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  targets: ["boot"],
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  fs.write(
    fp"${service_dir}/worker.xsh",
    """export let service = {
  name: "worker",
  kind: "longrun",
  command: process.command_argv("worker", ["worker"]),
  targets: ["boot"],
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1001 XSH_UNIX_DRY_RUN_EXIT_CODE=1 (xsh_bin()) (xinit_script()) -- scan boot ?
  test.eq(scan, "")?
  let logger_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status logger ?

  test.eq(
    logger_status,
    """logger running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let worker_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status worker ?

  test.eq(
    worker_status,
    """worker running pid=1002 ready=true log=append desired=up restarts=1
""",
  )?

  test.eq(unix_log.read_text()?.split("spawn_process_group").len(), 4)?
}

proc test_scan_gates_start_on_dependency_readiness(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "gate")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()

  # logger uses notify readiness and never signals, so it stays "starting".
  fs.write(
    fp"${service_dir}/logger.xsh",
    """export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  readiness: "notify",
  ready_timeout_ms: 100000,
  restart: {mode: "never"},
}
""",
  )?

  # app needs logger, so it must not start until logger is ready.
  fs.write(
    fp"${service_dir}/app.xsh",
    """export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {need: ["logger"]},
  restart: {mode: "never"},
}
""",
  )?

  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=3 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=poll XSH_UNIX_DRY_RUN_READY=0 (xsh_bin()) (xinit_script()) -- scan app ?
  test.eq(scan, "")?
  let logger_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status logger ?

  test.eq(
    logger_status,
    """logger starting pid=1000 ready=false log=append desired=up restarts=0
""",
  )?

  # app never started: its need is not ready, so no instance was spawned.
  let app_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status app ?

  test.eq(
    app_status,
    """app down pid=0 ready=false log=append desired=down restarts=0
""",
  )?

  test.eq(unix_log.read_text()?.split("spawn_process_group").len(), 2)?
}

proc test_scan_honors_inbox_down_request(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "inbox")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()
  fp"${run_dir}/inbox".mkdir()?

  fs.write(
    fp"${service_dir}/logger.xsh",
    """export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("logger", ["logger"]),
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  fs.write(
    fp"${service_dir}/app.xsh",
    """export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {need: ["logger"]},
  restart: {mode: "always", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  # Pre-post a desired-state "down" request for app. The scanner must drain the
  # inbox before reconciling, so app is parked (never spawned) while logger
  # still comes up — the control plane overriding the default desired state.
  fp"${run_dir}/inbox/app".write("down")?
  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=poll (xsh_bin()) (xinit_script()) -- scan app ?
  test.eq(scan, "")?
  let logger_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status logger ?

  test.eq(
    logger_status,
    """logger running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let app_status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status app ?

  test.eq(
    app_status,
    """app down pid=0 ready=false log=append desired=down restarts=0
""",
  )?

  test.ok(! fp"${run_dir}/inbox/app".exists()?)?
  test.eq(unix_log.read_text()?.split("spawn_process_group").len(), 2)?
}

proc test_scan_notify_readiness_reaches_running(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "notify-ready")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let unix_log = fp"${root}/unix.jsonl"
  service_dir.mkdir()

  fs.write(
    fp"${service_dir}/demo.xsh",
    """export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  readiness: "notify",
  restart: {mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  # A notify service is spawned with a readiness pipe (state "starting", not
  # ready); the scanner polls notify_ready and promotes it to running. The dry
  # run reports the service ready (XSH_UNIX_DRY_RUN_READY defaults to "1").
  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=2 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) XSH_UNIX_DRY_RUN_EVENT_KIND=poll (xsh_bin()) (xinit_script()) -- scan demo ?
  test.eq(scan, "")?
  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  let log_text = unix_log.read_text()?
  test.contains(log_text, "\"op\":\"notify_ready\"")?
  test.contains(log_text, "\"op\":\"notify_close\"")?
}

proc test_scan_notify_readiness_times_out(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "notify-timeout")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  service_dir.mkdir()

  fs.write(
    fp"${service_dir}/demo.xsh",
    """export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  readiness: "notify",
  ready_timeout_ms: 0,
  restart: {mode: "never", delay_ms: 0, max_delay_ms: 0, stable_after_ms: 1000},
}
""",
  )?

  # The service never signals readiness (XSH_UNIX_DRY_RUN_READY=0) and the ready
  # timeout is zero, so the scanner promotes it to running but not ready rather
  # than wedging.
  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=2 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_EVENT_KIND=poll XSH_UNIX_DRY_RUN_READY=0 (xsh_bin()) (xinit_script()) -- scan demo ?
  test.eq(scan, "")?
  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo running pid=1000 ready=false log=append desired=up restarts=0
""",
  )?
}

proc test_start_tolerates_optional_uses_failure(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "uses-optional")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let err = fp"${root}/err"
  service_dir.mkdir()

  # A oneshot whose command fails: it cannot start.
  fs.write(
    fp"${service_dir}/flaky.xsh",
    """export let service = {
  name: "flaky",
  kind: "oneshot",
  command: process.command_argv("/bin/false", ["false"]),
}
""",
  )?

  # app only *uses* flaky (optional), so flaky's start failure must be tolerated
  # and app still comes up.
  fs.write(
    fp"${service_dir}/app.xsh",
    """export let service = {
  name: "app",
  kind: "longrun",
  command: process.command_argv("app", ["app"]),
  dependencies: {uses: ["flaky"]},
  restart: {mode: "never"},
}
""",
  )?

  let started = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- start app ?

  test.eq(
    started,
    """app running pid=1000 ready=true log=append desired=up restarts=0
""",
  )?

  # needy *needs* flaky, so the same failure must abort its start.
  fs.write(
    fp"${service_dir}/needy.xsh",
    """export let service = {
  name: "needy",
  kind: "longrun",
  command: process.command_argv("needy", ["needy"]),
  dependencies: {need: ["flaky"]},
  restart: {mode: "never"},
}
""",
  )?

  let needy_status = run.status XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- start needy 2> $err
  assert_failed_with(needy_status, err, "flaky: start failed")?
}

proc test_reload_runs_hook_then_falls_back_to_sighup(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "reload")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let unix_log = fp"${root}/unix.jsonl"
  let touched = fp"${root}/reloaded"
  service_dir.mkdir()
  run_dir.mkdir()

  # A service exporting reload(): the hook runs and SIGHUP is not sent.
  fs.write(
    fp"${service_dir}/hooked.xsh",
    f"""export let service = {
  name: "hooked",
  kind: "longrun",
  command: process.command_argv("hooked", ["hooked"]),
  restart: {mode: "never"},
}

export proc reload() [fs, process, env, error] -> Result[Unit] {
  fs.write(Path(${json.encode(touched.display())?}), "reloaded")?
}
""",
  )?

  fp"${run_dir}/hooked.json".write(
    "{\"name\":\"hooked\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"restarts\":0}",
  )?

  let hooked = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(unix_log.display()) (xsh_bin()) (xinit_script()) -- reload hooked ?
  test.contains(hooked, "hooked running")?

  # The hook ran (wrote the sentinel) and, since reload runs the hook XOR sends
  # SIGHUP, no signal was sent (the dry-run log was never even created).
  test.eq(touched.read_text()?, "reloaded")?
  test.ok(! unix_log.exists()?)?

  # A service without reload(): the saved process group is sent SIGHUP.
  let plain_log = fp"${root}/plain.jsonl"

  fs.write(
    fp"${service_dir}/plain.xsh",
    """export let service = {
  name: "plain",
  kind: "longrun",
  command: process.command_argv("plain", ["plain"]),
  restart: {mode: "never"},
}
""",
  )?

  fp"${run_dir}/plain.json".write(
    "{\"name\":\"plain\",\"desired\":\"up\",\"state\":\"running\",\"pid\":1000,\"restarts\":0}",
  )?

  let _ = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_LOG=(plain_log.display()) (xsh_bin()) (xinit_script()) -- reload plain ?
  let plain_text = plain_log.read_text()?
  test.contains(plain_text, "\"op\":\"kill_process_group\"")?
  test.contains(plain_text, "\"signal\":\"HUP\"")?
}

proc test_finish_hook_runs_after_exit(ctx: TestContext) [fs, process, error] {
  let root = test.temp_dir(ctx, name: "finish")?
  let service_dir = fp"${root}/services"
  let run_dir = fp"${root}/run"
  let log_root = fp"${root}/logs"
  let touched = fp"${root}/finished"
  service_dir.mkdir()

  # A service that exits and won't restart, with a finish() cleanup hook. When
  # its child dies the scanner runs finish() before parking it.
  fs.write(
    fp"${service_dir}/demo.xsh",
    f"""export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv("demo", ["demo"]),
  restart: {mode: "never"},
}

export proc finish() [fs, process, env, error] -> Result[Unit] {
  fs.write(Path(${json.encode(touched.display())?}), "finished")?
}
""",
  )?

  let scan = run.text XINIT_SERVICE_DIR=(service_dir.display()) XINIT_RUN_DIR=(run_dir.display()) XINIT_LOG_ROOT=(log_root.display()) XINIT_TEST_MAX_EVENTS=1 XSH_UNIX_DRY_RUN=1 XSH_UNIX_DRY_RUN_EVENT_KIND=child XSH_UNIX_DRY_RUN_PID=1000 XSH_UNIX_DRY_RUN_EXIT_CODE=1 (xsh_bin()) (xinit_script()) -- scan demo ?
  test.eq(scan, "")?
  test.eq(touched.read_text()?, "finished")?
  let status = run.text XINIT_RUN_DIR=(run_dir.display()) XSH_UNIX_DRY_RUN=1 (xsh_bin()) (xinit_script()) -- status demo ?

  test.eq(
    status,
    """demo down pid=0 ready=false log=append desired=down restarts=0
""",
  )?
}
