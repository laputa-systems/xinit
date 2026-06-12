# xinit

`xinit` is a pure XSH init and service supervisor script.

This repository expects a sibling XSH checkout with debug binaries already
built:

```sh
cd ../xsh
cargo build --bin xsh --bin xsht
```

Then from this repository:

```sh
make verify
```

## Commands

```sh
../xsh/target/debug/xsh xinit.xsh -- /etc/inittab
../xsh/target/debug/xsh xinit.xsh -- boot
../xsh/target/debug/xsh xinit.xsh -- start SERVICE
../xsh/target/debug/xsh xinit.xsh -- restart SERVICE
../xsh/target/debug/xsh xinit.xsh -- status SERVICE
../xsh/target/debug/xsh xinit.xsh -- logs SERVICE
../xsh/target/debug/xsh xinit.xsh -- stop SERVICE
../xsh/target/debug/xsh xinit.xsh -- list
../xsh/target/debug/xsh xinit.xsh -- graph SERVICE_OR_TARGET
../xsh/target/debug/xsh xinit.xsh -- check [SERVICE_OR_PATH]
```

See `docs/INIT.md` for the full contract.
