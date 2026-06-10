# Work sandbox (code-server on local k3s/k3d)

An isolated, local Kubernetes (k3s, run via k3d) sandbox running code-server + a mobile
terminal + Claude Code, for **work** development. Designed around a strong
sandboxing principle: assume the agent could be compromised, so it holds **no
credentials** and has **exactly one network path out** — a boundary gateway it
can't bypass.

## How it's isolated

- **Single boundary gateway.** A small Docker container (`cs-<name>-gateway`),
  *outside* the cluster, is the only way in or out. The k3s node sits on a
  no-NAT docker network and routes all egress through the gateway, which:
  - **allowlists egress** — `tinyproxy` permits only listed domains; everything
    else is refused (and logged: `docker logs -f cs-<name>-gateway`).
  - **filters DNS** — `dnsmasq` resolves only allowlisted names and sinkholes the
    rest, so DNS tunnelling is dead.
  - **injects the GitHub credential** — Caddy holds your scoped GitHub PAT (git is
    rewritten to the gateway), so the **token is never in the agent's container or
    the cluster**. Anthropic auth is interactive OAuth (`claude /login`) so it works
    with enterprise/subscription accounts; that token does live in the pod's state,
    but the egress lock prevents exfiltrating it and it's revocable.
  - **fails closed** — the gateway doesn't forward, so anything not using the
    proxy simply can't reach the internet. `k8s-run` build pods inherit the proxy,
    so they're allowlisted too (the usual bypass is closed).
- **Workspace is mode-dependent** (see [Workspace modes](#workspace-modes)): either
  your host repos bind-mounted RW (`mount`), or an ephemeral volume reset to
  `origin` each boot (`clone`).
- **Scoped k8s access.** The pod's ServiceAccount can only create/inspect/delete
  pods in its own namespace (for `k8s-run`), nothing else — and there are no
  credential secrets in that namespace to steal.
- **baseline PodSecurity** namespace; no privileged/raw-hostPath pods. Agent
  containers drop all caps + run `seccomp:RuntimeDefault`.
- Local-only: ports published by k3d on `127.0.0.1` only, never on the LAN.

> Not org-approved by itself — even hardened, get R&D sign-off before treating it
> as policy-compliant for real work. A determined compromised agent can still
> dribble small data out through an *allowlisted* domain; the gateway kills bulk
> exfil + DNS tunnelling + credential theft, not every covert channel.

## Multiple instances

Run several sandboxes side by side with `--name` (default `work`). Each instance
is a fully separate cluster + gateway + state dir + docker networks + host ports,
so they never collide:

```bash
./up.sh                  # the default "work" instance (ports 4444/7681)
./up.sh --name test      # a second instance, own gateway/state, derived ports
./down.sh --name test    # tear down just that one
```

`work` keeps the original config (cluster `code-server-work`, ports 4444/7681,
state `~/.code-server-work/state`). Other names derive a unique subnet + ports
automatically (override with `VSCODE_PORT`/`TTYD_PORT`). Tip: when testing changes
to this setup, use a fresh `--name` so your running instance is never touched.

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
- **k3d** (v5+, provides k3s-in-docker), **kubectl**, **kustomize** (bundled with recent kubectl), **1Password CLI (`op`)**, `envsubst` (gettext), `base64`
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
./up.sh --name test     # a separate instance (see Multiple instances)
./up.sh --rebuild-gateway   # rebuild + recreate the gateway (e.g. after changing creds)
./down.sh               # delete the cluster + gateway + networks (state is kept)
./down.sh --purge-state # …and also delete the persisted state dir
```

`up.sh` builds the gateway image locally (no registry/CI) and reads your GitHub +
Anthropic credentials from 1Password straight into the gateway container — they
never enter the cluster.

The image tag defaults to the current commit's short SHA (precedence:
`--tag` > `IMAGE_TAG` env > git SHA). Commit + push so CI builds that SHA before
`up.sh`, or pass `--tag latest` / a known tag. (`base/kustomization.yaml` falls
back to `latest` for a direct `kubectl apply -k`.)

k3d publishes the ports natively on `127.0.0.1` (no `kubectl port-forward`):

- **VS Code** → http://localhost:4444
- **terminal** → http://localhost:7681

First boot pulls the image (and in `clone` mode, clones the repos) — give it a few
minutes.

After a host reboot the containers are stopped but not gone. A bare
`docker start cs-work-gateway k3d-code-server-work-server-0` brings them (and the
host ports) back — **but not** the node's default-route + DNS wiring, which are
runtime `docker exec` tweaks that don't survive a restart. So the reliable move is
to just re-run `up.sh` (idempotent — it re-wires egress without recreating the
cluster):

```bash
./up.sh                  # or: ./up.sh --name <instance>
```

> The containerd image-pull proxy *does* persist (it's `HTTP(S)_PROXY` env baked
> into the k3d node), so only the route/DNS need re-applying — which `up.sh` does.

## Customise

- **Repos (clone mode):** set `CLONE_REPOS` in `.env` (e.g.
  `CLONE_REPOS="your-org/your-service your-org/helm-charts"`); `up.sh` writes it
  into the `work-repos` configmap. Or edit that configmap's default in
  `base/configmaps.yaml`.
- **Repos (mount mode):** just point `REPOS_DIR` at the host dir holding them.
- **Image version:** bump `images[].newTag` in `base/kustomization.yaml`.
- **Claude auth:** run `claude /login` in the terminal (OAuth — works with
  enterprise/subscription accounts). Open the printed URL in your own browser,
  authorise, paste the code back. The token persists in the state dir across
  restarts, so it's a one-time step per instance.

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
to `STATE_DIR` (default `~/.code-server-<name>/state`, e.g. `~/.code-server-work/state`)
— a **dedicated, initially empty**, per-instance dir, **not** your real `~`. So it
**survives `down.sh`/recreate** (use `down.sh --purge-state` to wipe it): your
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
gateway/              boundary gateway image (Caddy git/anthropic proxy, tinyproxy
                      egress allowlist, dnsmasq DNS filter); built locally by up.sh
base/                 common manifests (ns, rbac, services, configmaps,
                      deployment skeleton, shared PVCs)
overlays/mount/       default: host repos bind-mount, light init
overlays/clone/       ephemeral workspace + reset-on-boot clone init
k3d-cluster.yaml.tmpl   rendered by up.sh (ports + notes/repos/dotfiles mounts)
up.sh / down.sh       bring up / tear down an instance (creds → gateway, not cluster)
```

## Network egress control

Egress is allowlisted **by default** via the boundary gateway (no CNI swap, no
NetworkPolicy needed — `networkpolicy.yaml` is now redundant). The baked defaults
(`gateway/allowlist.default`) cover github, dockerhub, npm/pypi/go, debian,
anthropic, open-vsx and stackoverflow. To allow more:

```bash
# .env
EGRESS_ALLOW="octopus.com mycompany.example.com"
```

Re-run `./up.sh --name <instance>` (or edit the live allowlist directly — it sits
in a `gateway/` dir **alongside** `$STATE_DIR`, e.g.
`~/.code-server-<name>/gateway/allowlist`, kept **outside** `$STATE_DIR` on purpose
so the agent pod can't reach it and rewrite its own egress policy) — the gateway
**live-reloads in ≤10s, with no pod restart**, so your session is undisturbed.
Watch what egresses:

```bash
docker logs -f cs-<name>-gateway      # tinyproxy + dnsmasq decisions
```

Each domain matches itself and its subdomains, anchored (so `evil-github.com`
won't match `github.com`). CONNECT is limited to ports 443/80.

### How the enforcement works (and its limits)
The k3s node is on a no-NAT docker network whose only route out is the gateway,
and the gateway doesn't IP-forward — so anything that ignores the proxy can't
reach the internet at all (fail-closed). This kills bulk exfil, DNS tunnelling,
and the `k8s-run` build-pod bypass, and keeps both credentials out of the agent.
It does **not** stop a compromised agent dribbling small data out through an
*allowlisted* domain — keep the allowlist to trusted infra.

## Known rough edges

- **Mount/notes perms:** host dirs are shared via k3d volume mount → hostPath PV.
  The container runs as uid 1000; ownership mapping differs across Docker Desktop
  (macOS, virtiofs — usually transparent) vs WSL2 (matches if your WSL uid is 1000).
  Mount mode sets `fsGroupChangePolicy: OnRootMismatch` so kubelet won't mass-chown
  your host repos. If Claude can't write, it's a host-permission quirk.
- **Mount mode is not ephemeral:** edits hit your real host files. Git is your undo
  for committed work; `REPOS_DIR` is the blast radius — keep it narrow.
- **git LFS / redirects:** the proxy forwards plain git smart-HTTP to github.com.
  LFS endpoints (different host) won't proxy; use exact `owner/repo` casing with
  `.git` to avoid redirects.
- Single-node k3s, RWO PVCs, `Recreate` strategy → one pod at a time.
