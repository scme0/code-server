# Work sandbox (code-server on local kind)

An isolated, local Kubernetes (kind) sandbox running code-server + a mobile
terminal + Claude Code, for **work** development. Designed around a few
sandboxing principles: the agent runs in a container, holds **no privileged
credentials**, and reaches GitHub only through a token-injecting proxy it can't
read.

## How it's isolated

- **No GitHub token in the agent's container.** A `git-proxy` sidecar (Caddy)
  holds your scoped PAT and injects auth; git is rewritten to talk to
  `localhost:8088`. Claude never sees the token.
- **Workspace is mode-dependent** (see [Workspace modes](#workspace-modes)): either
  your host repos bind-mounted RW (`mount`), or an ephemeral volume reset to
  `origin` each boot (`clone`).
- **Scoped k8s access.** The pod's ServiceAccount can only create/inspect/delete
  pods in its own namespace (for `k8s-run`), nothing else.
- **baseline PodSecurity** namespace; no privileged/raw-hostPath pods.
- Local-only: services published by kind on `127.0.0.1` only (NodePort +
  extraPortMappings), never on the LAN.

> Not org-approved by itself — even hardened, get R&D sign-off before treating it
> as policy-compliant for real work.

## Workspace modes

Set `WORKSPACE_MODE` in `.env`. Picked at `up.sh` time (it applies the matching
overlay: `overlays/mount` or `overlays/clone`).

| | **mount** (default) | **clone** |
|---|---|---|
| Workspace | your `REPOS_DIR` bind-mounted RW at `/data/workspace` | ephemeral volume, `git reset --hard origin` each boot |
| Boot speed | fast (repos already there) | slow (clones each repo via the proxy) |
| Edits | live on the host | discarded on restart (commit/push to keep) |
| PAT scope | read-only OK — you push from the host | needs write — agent pushes branches |
| Isolation | filesystem shared with host (scoped to `REPOS_DIR`) | full ephemeral isolation |
| Best for | day-to-day local work in "go mode" | locked-down / shareable / untrusted use |

In **mount** mode, list the repos you want via `REPOS` (e.g.
`REPOS="my-service my-lib"`) — each is mounted individually so
`/data/workspace` holds **only** those. This is both the blast radius and the
perf lever: mounting your whole `~/dev` makes code-server watch tens of GB over
virtiofs (slow). Leave `REPOS` empty to mount the whole `REPOS_DIR`. Agents still
run heavy/test work in disposable `k8s-run` pods (off-host).

## Prerequisites (macOS Apple Silicon · Windows WSL2)

- **Docker** running (Docker Desktop on macOS; Docker in your WSL2 distro)
- **kind**, **kubectl**, **kustomize** (bundled with recent kubectl), **1Password CLI (`op`)**, `envsubst` (gettext), `base64`
- Signed in to the work 1Password account: `eval $(op signin)`
- **WSL2:** run everything inside the WSL2 distro; keep `NOTES_DIR` on the WSL2
  filesystem (`/home/...`), not `/mnt/c/...`.

## Setup

```bash
cp .env.example .env        # then edit:
#  - WORKSPACE_MODE   (mount [default] or clone)
#  - REPOS            (mount mode: list specific repos to mount — recommended)
#  - REPOS_DIR        (mount mode: base dir / fallback to mount the whole dir)
#  - CLONE_REPOS      (clone mode: owner/repo slugs to clone each boot)
#  - NOTES_DIR        (optional; your work notes dir)
#  - OP_GH_PAT_REF    (op:// path to YOUR scoped GitHub PAT)
#  - OP_ANTHROPIC_REF (optional Anthropic key, or use `claude /login`)
```

Make a **fine-grained GitHub PAT** scoped to the work repos. Scope by mode:
- **mount:** `contents:read` + `pull_requests:read` (you push from the host).
- **clone:** `contents:read` + `contents:write` + `pull_requests:write` (agent pushes).

Store it in 1Password and point `OP_GH_PAT_REF` at it.

## Run

```bash
./up.sh                 # uses the image for the CURRENT git commit (CI tags by SHA)
./up.sh --latest        # use the `latest` image (e.g. while HEAD is still building)
./up.sh --tag <tag>     # use a specific image tag
./down.sh               # delete the cluster + all state
```

The image tag defaults to the current commit's short SHA (precedence:
`--tag` > `IMAGE_TAG` env > git SHA). Commit + push so CI builds that SHA before
`up.sh`, or pass `--tag latest` / a known tag. (`base/kustomization.yaml` falls
back to `latest` for a direct `kubectl apply -k`.)

kind publishes the ports natively on `127.0.0.1` (no `kubectl port-forward`):

- **VS Code** → http://localhost:4444
- **terminal** → http://localhost:7681

First boot pulls the image (and in `clone` mode, clones the repos) — give it a few
minutes.

After a host reboot the node container is stopped but not gone; just restart it
(no need to re-run `up.sh`) — ports come back with it:

```bash
docker start code-server-work-control-plane
```

## Customise

- **Repos (clone mode):** set `CLONE_REPOS` in `.env` (e.g.
  `CLONE_REPOS="your-org/your-service your-org/helm-charts"`); `up.sh` writes it
  into the `work-repos` configmap. Or edit that configmap's default in
  `base/configmaps.yaml`.
- **Repos (mount mode):** just point `REPOS_DIR` at the host dir holding them.
- **Image version:** bump `images[].newTag` in `base/kustomization.yaml`.
- **Claude auth:** set `OP_ANTHROPIC_REF`, or run `claude /login` in the terminal
  (persists on the config PVC across restarts).

## Shell / dotfiles

`DOTFILES_MODE` in `.env` controls the shell config. The default needs nothing.

| mode | behaviour |
|---|---|
| `default` | ships a sensible minimal `.zshrc` (PATH, history, completion, `fzf`+`zoxide`, aliases, git prompt). No secrets, no deps. |
| `chezmoi` | `chezmoi apply` from `DOTFILES_SRC` (your local source, RO-mounted). Runs with `--exclude=scripts,encrypted` and `CODE_SERVER_SANDBOX=1` set. |
| `host` | copies your own dotfiles from `DOTFILES_SRC` (a dir; uses its `.zshrc`). |
| `none` | bare shell. |

**chezmoi notes:** your dotfiles repo is likely **private**, and the in-container
PAT is work-scoped — it can't clone it. So `chezmoi` mode mounts your **local**
source instead of cloning — `DOTFILES_SRC` is **auto-detected** via
`chezmoi source-path` (set it only to override). It never runs `run_*` scripts or
decrypts (`--exclude=scripts,encrypted`). Gate cluster/secret files in your
`.chezmoiignore` behind the sandbox flag:

```gotemplate
{{ if env "CODE_SERVER_SANDBOX" }}
.kube
.talos
{{ end }}
```

(op-templated files like a 1Password-sourced kubeconfig should already be gated;
this also drops the static committed `.kube/config` so cluster creds never enter
the sandbox.) Changing `DOTFILES_MODE` after boot needs a pod restart:
`kubectl rollout restart deploy/code-server -n code-server-work`.

Notes (`NOTES_DIR`, optional): when set, mounted at `/mnt/notes` and symlinked to
`/data/workspace/notes` so they show in **both** the terminal and VS Code. Leave
`NOTES_DIR` unset to ignore notes entirely.

## Persistence

`/data` (the container's home + Claude config + code-server state) is host-mounted
to `STATE_DIR` (default `~/.code-server-work/state`) — a **dedicated, initially
empty** dir, **not** your real `~`. So it **survives `down.sh`/recreate**: your
Claude login, memories and history persist across teardowns.

- Claude config defaults to `~/.claude` (=`/data/home/.claude`). Dotfiles aliases
  to `~/.claude-home` / `~/.claude-work` work too — all live under the persisted
  `/data/home`.
- First boot **seeds** `~/.claude/CLAUDE.md` + `settings.json` only **if missing**
  (your persisted/dotfiles config wins). **Security note:** this relaxes the old
  per-boot force-reset — a compromised agent could persist a malicious
  `settings.json`/hook. Fine for a personal mount-mode sandbox; for the
  locked/shareable (clone) scenario, make the seeding in `common-init.sh`
  unconditional again so nothing executable persists.
- Only `STATE_DIR` and (mount mode) `REPOS_DIR`/`NOTES_DIR` are real host dirs; the
  workspace in clone mode and everything else stays ephemeral.

## Layout

```
base/                 common manifests (ns, rbac, services, git-proxy, configmaps,
                      deployment skeleton, shared PVCs)
overlays/mount/       default: host repos bind-mount, light init
overlays/clone/       ephemeral workspace + reset-on-boot clone init
kind-cluster.yaml.tmpl  rendered by up.sh (notes + optional repos/dotfiles mounts)
up.sh / down.sh / setup-secrets.sh
```

## Network egress control (optional, advanced)

`networkpolicy.yaml` is **not** applied by default: kind's default CNI (kindnet)
doesn't enforce NetworkPolicy. The git-proxy sidecar is the real GitHub control.
For enforced egress allowlisting you'd run kind with a policy CNI (Calico) and,
for FQDN/L7 rules, Cilium. Until then this is defence-in-depth/intent only.

## Known rough edges

- **Mount/notes perms:** host dirs are shared via kind extraMount → hostPath PV.
  The container runs as uid 1000; ownership mapping differs across Docker Desktop
  (macOS, virtiofs — usually transparent) vs WSL2 (matches if your WSL uid is 1000).
  Mount mode sets `fsGroupChangePolicy: OnRootMismatch` so kubelet won't mass-chown
  your host repos. If Claude can't write, it's a host-permission quirk.
- **Mount mode is not ephemeral:** edits hit your real host files. Git is your undo
  for committed work; `REPOS_DIR` is the blast radius — keep it narrow.
- **git LFS / redirects:** the proxy forwards plain git smart-HTTP to github.com.
  LFS endpoints (different host) won't proxy; use exact `owner/repo` casing with
  `.git` to avoid redirects.
- Single-node kind, RWO PVCs, `Recreate` strategy → one pod at a time.
