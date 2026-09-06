---
name: k8s-dev
description: >
  Use when the same build/test/analyze command will be run more than once in a
  session — iterating on a fix, checking before every push, or working through
  a failing test. k8s-dev keeps ONE pod warm and execs into it, so the
  toolchain is set up once instead of on every run. For a single one-off
  command, use k8s-run instead.
---

# k8s-dev — a warm pod for repeated checks

`k8s-run` is one-shot: every invocation starts a cold pod. That is right for a
single build and wrong for a check you want to run before every push, because
the setup cost is paid every time. For a Flutter project that meant minutes of
SDK preparation to save seconds of analysis — so in practice the check got
skipped, and CI found the mistakes instead.

`k8s-dev` keeps one pod alive and runs commands inside it.

## When to use which

| | |
|---|---|
| **k8s-run** | one command, once — a release build, a full suite before merging |
| **k8s-dev** | the same command repeatedly — analyze before each push, iterating on a failure |

## Usage

```sh
k8s-dev start --image IMAGE [--dir RELDIR] [--ttl SEC] [--setup CMD]
k8s-dev exec  'command'
k8s-dev stop
k8s-dev status
```

`start` is idempotent — if the pod is already running it is reused, so it is
safe to call again without checking.

## Idle timeout

PID 1 is a watchdog, not a `sleep`. Each `exec` touches a heartbeat, so an
active session keeps the pod alive and an abandoned one exits on its own after
`--ttl` seconds (default 3600).

This matters: a pod that lives until told otherwise is a pod someone forgets,
and it holds a node slot while idling. Still call `k8s-dev stop` when finished
— the timeout is a safety net, not the plan.

## Keep the toolchain inside the pod

Install SDKs into the pod's own filesystem (`/opt/...`), not into
`/data/workspace`. The workspace PVC is shared and network-backed, which causes
two distinct problems:

- **Lock contention.** Some toolchains lock their install directory — Flutter
  does. `flock` misbehaves over that filesystem, so a lock left by a killed pod
  is never released and every later pod waits on a holder that no longer
  exists.
- **Per-file latency.** Copying an SDK as loose files is dominated by file
  count, not size. If a warm SDK is worth caching on the PVC, cache it as a
  **tarball** and extract it into the pod: for Flutter, 315MB extracts in ~6s
  where the same tree copied loose took 41s and grew worse as its cache filled.

## Unpacking archives as root

If a toolchain fails extracting its own artefacts with
`tar: Cannot change ownership to uid ...`, set `TAR_OPTIONS=--no-same-owner`.
GNU tar reads it from the environment, so it applies to tar calls made by the
toolchain itself, which you cannot otherwise reach.

## Worked example — Flutter analyze on Stitches

```sh
k8s-dev start --image ghcr.io/cirruslabs/flutter@sha256:<digest> --dir stitches --ttl 1800

k8s-dev exec 'export TAR_OPTIONS=--no-same-owner
  mkdir -p /opt/fl && tar --no-same-owner -C /opt/fl -xzf /data/workspace/.flutter-3.47.2.tar.gz
  git config --global --add safe.directory /opt/fl/.flutter-3.47.2
  export PATH=/opt/fl/.flutter-3.47.2/bin:$PATH
  flutter pub get --enforce-lockfile'

k8s-dev exec 'export PATH=/opt/fl/.flutter-3.47.2/bin:$PATH; flutter analyze lib'

k8s-dev stop
```

Measured: 29s of setup once, then analyze in 20s and 12s as the analysis server
warms — against roughly 80s of CI that also requires a push first.
