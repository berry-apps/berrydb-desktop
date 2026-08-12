.PHONY: build test run app clean watch bench size release upload dev-sign-setup

build:
	swift build

test:
	swift test

# Performance benchmarks against the Docker matrix (docs/architecture/01 §2).
# Reports throughput / connect latency / memory; needs the test containers up
# (Tests/docker/compose.yml). Override row count with BENCH_ROWS=...
bench:
	BERRYDB_BENCH=1 \
	BERRYDB_BENCH_ROWS=$${BENCH_ROWS:-200000} \
	BERRYDB_TEST_POSTGRES=$${BERRYDB_TEST_POSTGRES:-127.0.0.1:54329:berry:berrypass:berrydb_test} \
	BERRYDB_TEST_MYSQL=$${BERRYDB_TEST_MYSQL:-127.0.0.1:33069:root:berrypass:berrydb_test} \
	swift test --filter Benchmarks 2>&1 | grep -E 'BENCH |Test .* (passed|failed)|Suite'

# Build once and (re)launch the app — no file watching. Stops a previous dev
# instance first so you always see the fresh build.
run:
	scripts/run.sh

# Rebuild + relaunch the app on every source change (build status via
# terminal + macOS notifications). Ctrl-C to stop.
watch:
	scripts/dev-watch.sh

# One-time: stable self-signed identity so Keychain doesn't re-prompt for the
# DB password on every rebuild (a fresh binary hash looks like a new app
# otherwise). Idempotent — safe to run again, a no-op once set up.
dev-sign-setup:
	scripts/dev-sign-setup.sh

app:
	swift build -c release
	scripts/make_app.sh release

# Signed + notarized release zip (needs .env — see deploy/README.md).
# Usage: make release 0.2.0 (VERSION=0.2.0 still works too).
release:
	bash deploy/release.sh $(or $(filter-out $@,$(MAKECMDGOALS)),$(VERSION))

# Swallows the version positional arg above so Make doesn't try to build it
# as a target too (e.g. "make release 0.2.0" would otherwise also fail with
# "No rule to make target '0.2.0'").
%:
	@:

# Publish the last release to R2 + rebuild the Sparkle appcast + purge CDN.
upload:
	python3 deploy/upload-release.py

# Guard the app-size + zero-runtime-deps targets (01 §2, 08 §6): fail if the
# release .app exceeds 100 MB or links a non-system runtime.
size:
	sh scripts/check-size.sh

clean:
	rm -rf .build dist
