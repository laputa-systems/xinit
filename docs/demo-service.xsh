export let service = {
  name: "demo",
  kind: "longrun",
  command: process.command_argv(/usr/bin/demo, ["demo", "--foreground"]),
  targets: ["boot"],
  dependencies: {need: ["net"], uses: ["logger"], after: ["firewall"]},
  restart: {mode: "on_failure", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
  logging: "append",
}

export proc ready() [fs, process, env, time, error] -> Result[Bool] {
  return fs.exists(/run/demo.sock)?
}
