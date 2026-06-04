---
name: k8s-run
description: >
  Use when asked to run tests, build, lint, or analyze a project whose
  runtime/SDK is NOT installed in this code-server container — e.g. "run the
  tests", "build the project", "dotnet build", "flutter test", "npm test",
  "go test", "run in a pod". k8s-run executes the command in a disposable
  Kubernetes pod with a toolchain image you choose, mounting the workspace.
---

# k8s-run — disposable k8s pods for build/test/analyze

`k8s-run` runs any command in a throwaway pod with read-write access to
`/data/workspace`. Use it whenever this container lacks the required runtime.

## When to use
- Run tests/build/lint/analyze and the tool (dotnet, flutter, node, go, rust,
  python, ...) isn't installed here ("command not found").
- User says "run in a pod" / "use k8s-run".

Do NOT use for editing files, reading code, git, or kubectl — those work locally.

## ⚠️ Never run related builds/tests in parallel

Every `k8s-run` pod mounts the **same** `/data/workspace` PVC — one shared volume,
not a copy per pod. Launching multiple pods that touch the **same project**
concurrently makes them fight over the same files (build output dirs, package
caches, lock files, generated code, test scratch dirs/databases) and corrupt each
other's state: half-written artifacts, `text file busy`, lock-file deadlocks,
flaky/garbage results, or one pod clobbering another's build mid-run.

- Run one build/test per project at a time; chain steps in a single `--cmd`
  (`a && b && c`) instead of firing parallel pods.
- Don't start a second run of the same suite while the first is live — wait, or
  run it in the background and watch the one log.
- Only parallelize across **different** projects (`--dir`) that share no output
  paths, and prefer sequential when unsure.

## CLI
```
k8s-run --image IMAGE --cmd CMD [--dir RELDIR] [--keep] [--timeout SEC]
```
Namespace + workspace PVC are preset for this sandbox (KRUN_NS env) — do NOT
pass --ns/--pvc. `--dir` is a path under /data/workspace (slashes are fine).

## Common images
| Tool | Image |
|---|---|
| .NET / C# | mcr.microsoft.com/dotnet/sdk:10.0 |
| Node | node:20, node:22 |
| Go | golang:1.22 |
| Python | python:3.12 |
| Rust | rust:1.78 |
| Flutter | ghcr.io/cirruslabs/flutter:stable |

## Examples
```bash
k8s-run --image mcr.microsoft.com/dotnet/sdk:10.0 --dir my-service/source --cmd "dotnet build My.sln --nologo"
k8s-run --image node:20 --dir my-webapp --cmd "npm ci && npm test"
k8s-run --image golang:1.22 --dir my-service --cmd "go test ./..."
```

## Notes
- Output streams live; the pod auto-deletes after (use --keep to inspect).
- Debug a kept pod: kubectl logs -n code-server-work <pod> ;
  kubectl exec -n code-server-work <pod> -- sh
- Stale krun pods (>1 day) are auto-cleaned each run.
