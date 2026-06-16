# YOLO Docker — Disposable, Persistent Coding-Agent Sandboxes

A self-contained [code-server](https://github.com/coder/code-server) environment
designed for running a coding agent in **"YOLO mode"** — i.e. letting the agent
do whatever it wants, including running as **root** and installing arbitrary
system packages and tools, without touching your host machine.

The trick: the container's **entire root filesystem is overlaid onto a persistent
Docker volume**. Anything the agent installs (`apt install`, `pip`, `npm -g`,
compilers, language runtimes, random binaries dropped in `/usr/local/bin`, etc.)
**sticks around** across restarts. When you're done with a project, you wipe the
volume and get a pristine environment back for the next one.

You can run several isolated agents at once — agent 1, agent 2, ... — each with
its own port and its own persistent disk.

---

## Why this exists

Coding agents are most useful when they can freely set up their own toolchain.
But you don't want an autonomous agent running as root **on your actual machine**.
This project gives each agent:

- **Root + sudo** inside a container, so it can install anything.
- **A persistent overlay root**, so installs and config survive restarts.
- **Isolation from the host**, so the blast radius is the container/volume.
- **A one-command reset**, so each new project starts clean.

> ⚠️ **Security note:** The container runs `privileged: true` (required for the
> in-container `mount`/`chroot` overlay trick) and ships with hardcoded
> credentials. Treat each container as a powerful, semi-trusted box. **Do not
> expose the ports to the public internet.** Keep them on `localhost` or a
> trusted network only. See [Security](#security) below.

---

## How it works

```
┌───────────────────────────────────────────────────────────┐
│ Container (privileged)                                    │
│                                                           │
│   lowerdir = /            (pristine code-server image)    │
│   upperdir = /mnt/persistent/upper   ← writes land here   │
│   workdir  = /mnt/persistent/work                         │
│        │                                                  │
│        ▼  OverlayFS                                       │
│   merged  = /mnt/persistent/merged                        │
│        │                                                  │
│        ▼  chroot + exec /init                             │
│   code-server runs inside the merged root                 │
└───────────────────────────┬───────────────────────────────┘
                            │  /mnt/persistent
                            ▼
                Docker volume: agentN_agent-root
                (survives restarts; deleted on "destroy")
```

- [`Dockerfile`](Dockerfile) builds on `lscr.io/linuxserver/code-server` and
  installs a custom [`entrypoint.sh`](entrypoint.sh).
- [`entrypoint.sh`](entrypoint.sh) creates an OverlayFS where the **lower** layer
  is the read-only base image and the **upper** layer lives on the persistent
  volume. It then `chroot`s into the merged root and hands off to code-server's
  normal `/init`. The result: every filesystem change the agent makes is written
  to the volume.

  Two non-obvious details make this actually work (both verified by live testing):

  1. **The volume must not be inside the overlay's lower layer.** OverlayFS
     forbids `upperdir`/`workdir` from living inside `lowerdir`. Since the volume
     is mounted at `/persist` (under `/`), naively using `lowerdir=/` would put
     the upper dir inside the lower dir and silently discard all writes on
     teardown. The entrypoint sidesteps this by doing a **non-recursive bind of
     `/` to `/lower`** — a non-recursive bind does not pull in submounts, so
     `/lower` is the pristine image with an *empty* `/lower/persist`. Using
     `lowerdir=/lower` keeps upper/work safely outside the lower layer.
  2. **DNS must be wired into the chroot.** Docker manages `/etc/resolv.conf`,
     `/etc/hosts`, and `/etc/hostname` on the outer root; inside the chroot they
     are stale/empty, which breaks `apt`. The entrypoint bind-mounts the live
     copies into the merged tree so package installs work.
- [`docker-compose.yml`](docker-compose.yml) wires up the volume, ports, and
  password. The volume key is static (`agent-root`); per-agent isolation comes
  from running each agent under its own compose **project** (`agent1`, `agent2`,
  ...), so the real volumes are `agent1_agent-root`, `agent2_agent-root`, etc.

---

## Requirements

- Linux host with a kernel that supports **OverlayFS** (standard on modern Linux).
- Docker Engine with either the `docker compose` plugin (v2) or legacy
  `docker-compose` (v1). The helper script auto-detects which you have.

---

## Quick start

```bash
# Start agent 1 (builds the image on first run). Opens on port 8441.
./agent.sh up 1

# Open the editor in your browser:
#   http://localhost:8441
# Password: a2s47df8   (see docker-compose.yml)
```

Inside the editor's terminal, the agent (or you) can install whatever is needed:

```bash
sudo apt update && sudo apt install -y build-essential
pip install --break-system-packages some-tool
npm install -g some-cli
```

Stop the container later and everything you installed is still there:

```bash
./agent.sh down 1     # stop, KEEP state
./agent.sh up 1       # back exactly where you left off
```

When the project is finished and you want a clean slate:

```bash
./agent.sh destroy 1  # stop + WIPE the volume (asks for confirmation)
./agent.sh up 1       # pristine environment again
```

---

## Running multiple agents

Each agent number gets its own port and its own persistent disk, so you can run
several in parallel:

```bash
./agent.sh up 1    # http://localhost:8441
./agent.sh up 2    # http://localhost:8442
./agent.sh up 3    # http://localhost:8443
```

Agent **N** maps to host port **8440 + N**. Each agent's installs and files are
completely independent.

---

## The `agent.sh` helper

[`agent.sh`](agent.sh) is the single entry point for managing agents.

| Command                  | What it does                                                        |
| ------------------------ | ------------------------------------------------------------------- |
| `./agent.sh up <N>`      | Build (if needed) and start agent N in the background.              |
| `./agent.sh down <N>`    | Stop and remove agent N's container. **Persistent state is kept.**  |
| `./agent.sh destroy <N>` | Stop, remove, and **delete** agent N's volume (full reset).         |
| `./agent.sh logs <N>`    | Follow agent N's logs.                                              |
| `./agent.sh info <N>`    | Print the URL, password, and raw compose commands for agent N.      |
| `./agent.sh status`      | List all running agent containers.                                  |

`destroy` requires you to type `yes` to confirm, because it permanently deletes
the agent's installed software and files.

### Equivalent raw commands

If you'd rather not use the script, the helper just runs these (shown for agent 1):

```bash
# Start
AGENT_ID=1 PORT=8441 docker compose -p agent1 up -d --build

# Stop (keep state)
docker compose -p agent1 down

# Destroy (reset persistence for a new project)
docker compose -p agent1 down --volumes
```

`./agent.sh info <N>` prints the exact commands for any agent number.

---

## Persistence model

- **What persists:** the entire root filesystem changes — installed packages,
  binaries in `/usr/local`, system config, home directory, project files. It all
  lives in the `agentN_agent-root` volume via the OverlayFS upper layer.
- **`down` keeps it.** Stopping/removing the container does not touch the volume.
- **`destroy` wipes it.** Use this between unrelated projects to avoid one
  project's leftover tooling polluting the next.

---

## Security

This setup intentionally trades isolation strictness for agent freedom. Be aware:

- The container runs **`privileged: true`**, which is required for the in-container
  `mount`/`chroot` overlay. A privileged container has broad access to the host
  kernel — this is **not** a hardened sandbox.
- Credentials are **hardcoded** in [`docker-compose.yml`](docker-compose.yml)
  (`PASSWORD`, `SUDO_PASSWORD`). Change them, and prefer moving them into an
  untracked `.env` file rather than committing secrets.
- **Bind to localhost / a trusted network only.** Never expose these ports to the
  open internet.
- Treat each volume as containing whatever an autonomous agent decided to install.
  When in doubt, `destroy` and start fresh.

---

## Cloning code from your host (SSH / git)

You can SSH from inside the container back to your host machine and `git clone`
local repos. The container reaches the host via the Docker bridge **gateway IP**
(not `localhost`, which inside the container refers to the container itself).

1. Find the gateway IP for the agent's network (this is your host from the
   container's point of view):
   ```bash
   docker network inspect agent<N>_default --format '{{ (index .IPAM.Config 0).Gateway }}'
   # e.g. 172.20.0.1
   ```
   On Docker Desktop (macOS/Windows) you can instead use the hostname
   `host.docker.internal`.

2. Make sure your host is running an SSH server (`sshd` on port 22) and that your
   user account accepts your key/password.

3. From the **editor terminal** inside code-server:
   ```bash
   # one-off clone over SSH (replace user + path to your repo)
   git clone ssh://youruser@172.20.0.1/home/youruser/path/to/repo.git

   # or add a convenient host alias in ~/.ssh/config (persists on the volume!)
   cat >> ~/.ssh/config <<'CFG'
   Host hostmachine
       HostName 172.20.0.1
       User youruser
   CFG
   git clone hostmachine:/home/youruser/path/to/repo.git
   ```

Because `~/.ssh/` lives in the persistent root, your keys and `ssh/config` survive
`down`/`up` (and are wiped by `destroy`). `git` and `ssh` are already installed in
the image.

> Tip: the gateway IP can change if you recreate the network. The `~/.ssh/config`
> alias just needs its `HostName` updated if that happens.

## Troubleshooting

- **An `apt install <pkg>` says "Unable to locate package".** Run `apt-get update`
  first inside the editor terminal. Also note some packages (e.g. `cowsay`) have
  been removed from current Ubuntu repos and simply aren't installable anymore —
  that's a repo issue, not a persistence issue.
- **"I installed something with `docker exec` and it vanished."** `docker exec`
  drops you into the container's **outer** root, *not* the persistent chroot that
  code-server runs in. Installs done that way do **not** persist. Always install
  from **inside the code-server editor terminal** (or its web UI), which runs in
  the persistent root. Files created in the editor land on the volume.
- **Verifying persistence yourself:** create a file or install a package from the
  editor terminal, then `./agent.sh down <N>` followed by `./agent.sh up <N>`.
  Your file/package should still be there. This was validated end-to-end during
  development (e.g. `apt install tree` survived a full down/up cycle).

## Files

| File                                       | Purpose                                                     |
| ------------------------------------------ | ----------------------------------------------------------- |
| [`agent.sh`](agent.sh)                     | Management CLI (up / down / destroy / logs / info / status).|
| [`docker-compose.yml`](docker-compose.yml) | Service, ports, password, and persistent volume.            |
| [`Dockerfile`](Dockerfile)                 | Builds code-server with the custom overlay entrypoint.      |
| [`entrypoint.sh`](entrypoint.sh)           | Sets up the OverlayFS and chroots into the persistent root. |
