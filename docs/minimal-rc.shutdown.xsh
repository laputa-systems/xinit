#!/bin/xsh
for hook in g"/usr/lib/init/rc.d/*.pre.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}

for hook in g"/etc/rc.d/*.pre.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}

let swapoff_all_result = linux.swapoff_all()
let umount_all_result = linux.umount_all(types: ["nosysfs", "proc", "devtmpfs", "tmpfs"])
let remount_root_result = linux.mount("", /, fstype: "", options: ["remount", "ro"])
fs.sync()?

for hook in g"/usr/lib/init/rc.d/*.post.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}

for hook in g"/etc/rc.d/*.post.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}
