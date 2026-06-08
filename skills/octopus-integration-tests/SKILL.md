---
name: octopus-integration-tests
description: >
  Use when asked to run, debug, or update OctopusDeploy backend integration
  tests (the Octopus.IntegrationTests project) inside this code-server sandbox
  — e.g. "run the integration tests", "run SchemaHasNotChangedTests", "this
  integration test fails in CI, run it locally", "regenerate the schema
  snapshot". Covers connecting the tests to the SQL Server running in Docker
  on the host, since this pod has no dotnet and the default `localhost`
  connection string does not work from inside a pod.
---

# Running OctopusDeploy integration tests in the sandbox

The `Octopus.IntegrationTests` project boots Octopus Server in-process and
requires a real SQL Server. In this sandbox the database runs in **Docker on
the host**, while you are working inside a Kubernetes pod that has **no dotnet
installed**. Two problems follow, and this skill solves both.

## The two gotchas

1. **No dotnet here.** Run tests in a throwaway pod via the `k8s-run` skill,
   using the .NET SDK image. (`dotnet --version` in this container returns
   "command not found".)
2. **`localhost` is the pod, not the host.** The tests default
   `SQL_IntegrationTest_Instance` to `localhost`/`(local)`. Inside a pod that
   resolves to the pod itself, so the connection fails. Point it at
   `host.docker.internal` — cluster DNS (gateway dnsmasq) resolves that to the
   boundary gateway, which runs a raw-TCP relay re-originating port `1433` to the
   real host. Works from freshly spawned `k8s-run` pods too.

   This is **not** a database bind/firewall issue — the DB already accepts
   non-localhost traffic; only the connection target needs changing.

   **Requires `HOST_RELAY_PORTS=1433` in `work-kind/.env`** (then re-run
   `./up.sh`). The egress boundary blocks all non-allowlisted traffic and SQL is
   raw TCP (not HTTP, so the egress proxy can't carry it); the host relay is the
   one sanctioned path. Without it the connection fails with a timeout — that is
   the boundary working, not a DB problem.

## Run a targeted test

Always filter to the area you are touching — the suite is huge. Full
restore + build of `Octopus.IntegrationTests` takes ~10–15 minutes in a fresh
pod (no incremental cache between runs), so run in the **background** and watch
the log rather than blocking.

```bash
k8s-run --image mcr.microsoft.com/dotnet/sdk:10.0 --dir OctopusDeploy --timeout 2400 --cmd '
export SQL_IntegrationTest_Instance=host.docker.internal   # NOT localhost — that is the pod
export SQL_IntegrationTest_Username=sa
export SQL_IntegrationTest_Password="Password01!"
export AssentNonInteractive=true                            # stop Assent blocking on a GUI diff
export Octopus__MessageBus__MaxConcurrentPumps=1            # big speedup on Linux
dotnet test source/Octopus.IntegrationTests/Octopus.IntegrationTests.csproj \
  --filter "FullyQualifiedName~SchemaHasNotChangedTests" \
  -v minimal --logger "console;verbosity=normal"
'
```

- `--dir OctopusDeploy` is relative to `/data/workspace` (the mounted PVC).
- Combine areas with `|`: `--filter "FullyQualifiedName~A|FullyQualifiedName~B"`.
- Match the SDK in `global.json` (currently `10.0.x` → image `mcr.microsoft.com/dotnet/sdk:10.0`).

### Background + monitor pattern

Because the build is long, kick it off detached and watch for terminal
signals (build failure, SQL connection failure, or pass/fail) instead of
polling:

```bash
# launch (run_in_background), tee to a log:
... k8s-run ... 2>&1 | tee /tmp/itest.log
# then monitor the log for the lines you would act on:
tail -f /tmp/itest.log | grep -E --line-buffered \
  "Build FAILED|error CS|Passed Octopus|Failed Octopus|Could not establish connection|Login failed|Total tests|Test Run|FAILED \(exit"
```

## Database connection environment variables

| Variable | Value in sandbox | Why |
|---|---|---|
| `SQL_IntegrationTest_Instance` | `host.docker.internal` | Reach the host's Docker SQL from the pod |
| `SQL_IntegrationTest_Username` | `sa` | |
| `SQL_IntegrationTest_Password` | `Password01!` | |
| `AssentNonInteractive` | `true` | Assent otherwise opens a GUI diff and hangs the runner |
| `Octopus__MessageBus__MaxConcurrentPumps` | `1` | Faster start/run on Linux (a few message-pump tests may need it unset) |
| `SQL_IntegrationTest_ReuseExistingDatabase` | `true` (optional) | Keep data between runs while debugging; also set `SQL_IntegrationTest_ReuseSnapshot=false` |

See `docs/documents/safety-nets/integration-tests/` in the repo for the full
list and lifecycle.

## Regenerating the schema snapshot (SchemaHasNotChangedTests)

When a branch adds/changes DB schema, both `SchemaHasNotChangedCheck` (the
production SystemIntegrityCheck) and `TheSchemaShouldMatchTheSnapshot` (Assent)
fail. They read **one** file:

```
source/Octopus.IntegrationTests/Server/Orchestration/SystemIntegrityCheck/Approved/Schema.approved.txt
```

(`Octopus.Core` embeds it via a csproj `<EmbeddedResource ... Link=...>`, so
updating this single file fixes both tests.)

To regenerate:

1. Run `TheSchemaShouldMatchTheSnapshot` (command above). On failure Assent
   writes `Schema.received.txt` next to the approved file, containing the
   current schema.
2. The committed approved file is **CRLF** (`.gitattributes`:
   `*.approved.* -text`); Assent normalizes line endings when comparing, so
   keep CRLF to avoid a whole-file diff. The received file is LF — convert it:

   ```bash
   A=source/Octopus.IntegrationTests/Server/Orchestration/SystemIntegrityCheck/Approved
   perl -0777 -pe 's/\r\n/\n/g; s/\n/\r\n/g' "$A/Schema.received.txt" > "$A/Schema.approved.txt"
   ```
3. Re-run both schema tests to confirm green. `Schema.received.txt` is
   gitignored; delete it.

## Sandbox quirks

- **ARM64 builds** (Apple Silicon / orbstack) need
  `source/Directory.Build.targets` — a shim that works around a `protoc`
  segfault on linux/arm64. It is intentionally **untracked; do not commit it.**
  Without it, proto compilation fails with `protoc exited with code 139`.
- Not installed here: `file`, `xxd`, `nc`/`nmap`. Available:
  `python3`, `perl`, `awk`, `sed`, `git`, `kubectl`.
- Inspect a kept pod: add `--keep`, then
  `kubectl logs -n code-server-work <pod>` /
  `kubectl exec -n code-server-work <pod> -- sh`.
