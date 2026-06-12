.PHONY: check fmt-check test verify

XSH ?= ../xsh/target/debug/xsh
XSHT ?= ../xsh/target/debug/xsht
XSH_FILES := xinit.xsh tests/xinit.xsh docs/minimal-rc.boot.xsh docs/minimal-rc.shutdown.xsh docs/demo-service.xsh

check:
	$(XSHT) check $(XSH_FILES)

fmt-check:
	$(XSHT) fmt --check $(XSH_FILES)

lint:
	$(XSHT) lint $(XSH_FILES)

test:
	$(XSHT) test --fail-fast tests

verify: check fmt-check lint test
