# code-server sandbox

A sandboxed environment for running [Claude Code](https://claude.com/claude-code)
against your own repos: [code-server](https://github.com/coder/code-server) (VS
Code in the browser) + a mobile-friendly terminal + Claude Code, on a local
[kind](https://kind.sigs.k8s.io/) Kubernetes cluster.

The agent runs in a container, holds **no privileged credentials**, and reaches
GitHub only through a token-injecting proxy it can't read. Heavy build/test work
runs in disposable pods via `k8s-run`.

## Get started

See **[`local-secure/README.md`](local-secure/README.md)** for prerequisites, setup,
and the two workspace modes (bind-mount your host repos, or ephemeral
clone-on-boot).

## Layout

```
Dockerfile            the code-server + Claude Code + tooling image
local-secure/         the local k3s (k3d) cluster + Kubernetes manifests + up/down scripts
k8s-run               disposable-pod runner for build/test/analyze
mobile-controller.js  mobile terminal helper
```

## License

[MIT](LICENSE).
