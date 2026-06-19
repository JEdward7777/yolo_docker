#!/bin/bash
#
# agent.sh - Manage stateful code-server agent containers.
#
# Each agent is an isolated code-server instance with its own persistent
# OverlayFS-backed root volume (agentN_agent-root). Agent N listens on port
# 8440 + N by default (agent 1 -> 8441, agent 2 -> 8442, ...).
#
# Usage:
#   ./agent.sh up      <N>         Build (if needed) and start agent N
#   ./agent.sh down    <N>         Stop & remove agent N's container (state PRESERVED)
#   ./agent.sh destroy <N>         Stop, remove, and WIPE agent N's persistent volume
#   ./agent.sh copy    <SRC> <DST> Mirror agent SRC's volume onto agent DST (OVERWRITES DST)
#   ./agent.sh export  <N> [FILE]  Export agent N's volume to a .tar.gz archive
#   ./agent.sh import  <FILE> <N>  Import a .tar.gz archive into agent N (OVERWRITES state)
#   ./agent.sh logs    <N>         Follow logs for agent N
#   ./agent.sh status              Show status (UP/DOWN) of all agents
#   ./agent.sh info    <N>         Show connection info for agent N
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------
BASE_PORT=8440          # Agent N maps host port (BASE_PORT + N) -> container 8443
PROJECT_PREFIX="agent"  # docker-compose project name prefix (-> agent1, agent2, ...)
PASSWORD="a2s47df8"     # Must match PASSWORD in docker-compose.yml
COMPOSE_FILE="docker-compose.yml"

# --- Helpers -----------------------------------------------------------------

# Resolve which docker compose CLI is available (v2 plugin or legacy v1).
if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
else
    echo "ERROR: Neither 'docker compose' nor 'docker-compose' is installed." >&2
    exit 1
fi

usage() {
    cat <<'EOF'
Usage: ./agent.sh <command> [agent-number]

Commands:
  up      <N>          Build (if needed) and start agent N in the background.
  down    <N>          Stop and remove agent N's container. Persistent state is KEPT.
  destroy <N>          Stop, remove, and DELETE agent N's persistent volume (full reset).
  copy    <SRC> <DST>  Stop both agents, then mirror agent SRC's volume onto agent
                       DST (OVERWRITES DST's state). Both agents are left stopped.
  export  <N> [FILE]   Export agent N's volume to a .tar.gz archive. Agent is stopped
                       first and left stopped. FILE defaults to ./agent_N_export.tar.gz.
  import  <FILE> <N>   Import a .tar.gz archive into agent N, REPLACING all existing
                       state. Agent is stopped first and left stopped.
  logs    <N>          Follow the logs for agent N.
  info    <N>          Print connection details for agent N.
  status               Show status (UP/DOWN) of all known agents.

Examples:
  ./agent.sh up 1                          # start agent 1 on port 8441
  ./agent.sh up 2                          # start agent 2 on port 8442
  ./agent.sh down 1                        # stop agent 1, keep its files
  ./agent.sh destroy 1                     # nuke agent 1's state for a fresh project
  ./agent.sh copy 1 2                      # clone agent 1's volume onto agent 2 (wipes agent 2)
  ./agent.sh export 3                      # export agent 3 -> ./agent_3_export.tar.gz
  ./agent.sh export 3 ./backup.tar.gz      # export agent 3 -> ./backup.tar.gz
  ./agent.sh import ./agent_3_export.tar.gz 3  # import archive into agent 3 (wipes agent 3)
EOF
}

# Validate the agent number argument.
require_agent_id() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        echo "ERROR: Missing agent number." >&2
        usage
        exit 1
    fi
    if ! [[ "$id" =~ ^[0-9]+$ ]] || (( id < 1 )); then
        echo "ERROR: Agent number must be a positive integer (got '$id')." >&2
        exit 1
    fi
}

# Compute the host port for a given agent.
agent_port() {
    echo $(( BASE_PORT + $1 ))
}

# The docker-compose project name isolates each agent's compose state so that
# 'down --volumes' only affects the targeted agent.
project_name() {
    echo "${PROJECT_PREFIX}${1}"
}

# The real Docker volume name for an agent (compose namespaces it with the
# project name, e.g. agent1 -> agent1_agent-root).
volume_name() {
    echo "$(project_name "$1")_agent-root"
}

# True if the named Docker volume currently exists.
volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

# Run docker compose for a specific agent with the right env + project name.
compose_for_agent() {
    local id="$1"; shift
    local port
    port="$(agent_port "$id")"
    AGENT_ID="$id" PORT="$port" \
        "${DC[@]}" -f "$COMPOSE_FILE" -p "$(project_name "$id")" "$@"
}

print_info() {
    local id="$1"
    local port
    port="$(agent_port "$id")"
    cat <<EOF

================ Agent ${id} ================
  URL:       http://localhost:${port}
  Password:  ${PASSWORD}
  Volume:    $(project_name "$id")_agent-root  (persistent state)
  Project:   $(project_name "$id")

  Useful commands:
    Start:    AGENT_ID=${id} PORT=${port} ${DC[*]} -p $(project_name "$id") up -d
    Stop:     ${DC[*]} -p $(project_name "$id") down            # keeps state
    Reset:    ${DC[*]} -p $(project_name "$id") down --volumes  # wipes state
    Logs:     ${DC[*]} -p $(project_name "$id") logs -f
============================================
EOF
}

# --- Commands ----------------------------------------------------------------

cmd_up() {
    local id="$1"
    require_agent_id "$id"
    echo ">> Starting agent ${id} on port $(agent_port "$id")..."
    compose_for_agent "$id" up -d --build
    print_info "$id"
}

cmd_down() {
    local id="$1"
    require_agent_id "$id"
    echo ">> Stopping agent ${id} (persistent state preserved)..."
    compose_for_agent "$id" down
    echo ">> Agent ${id} stopped. Its volume '$(project_name "$id")_agent-root' is intact."
}

cmd_destroy() {
    local id="$1"
    require_agent_id "$id"
    echo "!! WARNING: This will permanently delete agent ${id}'s persistent state."
    read -r -p "Type 'yes' to confirm destroying agent ${id}: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo ">> Aborted. Nothing was destroyed."
        exit 0
    fi
    echo ">> Destroying agent ${id} (container + volume)..."
    compose_for_agent "$id" down --volumes
    # 'down --volumes' already removes the project-scoped volume
    # ("<project>_agent-root"). As a belt-and-suspenders cleanup, also remove
    # any legacy "agent-${id}-root" volume from older fixed-name setups so the
    # next 'up' always starts from a pristine image.
    docker volume rm "$(project_name "$id")_agent-root" 2>/dev/null || true
    docker volume rm "agent-${id}-root" 2>/dev/null || true
    echo ">> Agent ${id} destroyed. Next 'up' will start fresh from the base image."
}

cmd_copy() {
    local src="$1"
    local dst="$2"
    require_agent_id "$src"
    require_agent_id "$dst"

    if [[ "$src" == "$dst" ]]; then
        echo "ERROR: Source and destination agents must differ (got '$src' and '$dst')." >&2
        exit 1
    fi

    local src_vol dst_vol
    src_vol="$(volume_name "$src")"
    dst_vol="$(volume_name "$dst")"

    if ! volume_exists "$src_vol"; then
        echo "ERROR: Source volume '${src_vol}' does not exist." >&2
        echo "       Agent ${src} has no persistent state to copy (was it ever started?)." >&2
        exit 1
    fi

    echo "!! WARNING: This will OVERWRITE agent ${dst}'s state with a copy of agent ${src}'s."
    echo "!!          Agent ${dst}'s volume '${dst_vol}' will be mirrored to match agent ${src}'s"
    echo "!!          (files not present in the source will be DELETED)."
    read -r -p "Type 'yes' to confirm copying agent ${src} -> agent ${dst}: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo ">> Aborted. Nothing was copied."
        exit 0
    fi

    # Stop both agents so nothing is writing to the volumes during the copy.
    # 'down' is a no-op (aside from a warning) if the agent is already stopped.
    echo ">> Stopping agent ${src} (source)..."
    compose_for_agent "$src" down
    echo ">> Stopping agent ${dst} (destination)..."
    compose_for_agent "$dst" down

    # Keep the destination volume if it already exists so rsync can perform an
    # incremental mirror; only create it when missing.
    if volume_exists "$dst_vol"; then
        echo ">> Reusing existing destination volume '${dst_vol}' (incremental mirror)."
    else
        echo ">> Creating destination volume '${dst_vol}'..."
        docker volume create "$dst_vol" >/dev/null
    fi

    # Mirror the source volume onto the destination using rsync in a throwaway
    # Alpine container. Alpine is an official, well-maintained image and we
    # install a fresh rsync at runtime so the tool never depends on a stale,
    # third-party image baking in an aging rsync/apt.
    #   -a            archive (perms, times, symlinks, ownership)
    #   -H -A -X      preserve hard links, ACLs, extended attributes
    #   --numeric-ids preserve raw uid/gid (root files; no shared user db here)
    #   --delete      mirror: remove dest files not present in the source
    echo ">> Copying agent ${src}'s volume -> agent ${dst}'s volume via rsync..."
    docker run --rm \
        -v "${src_vol}:/from:ro" \
        -v "${dst_vol}:/to" \
        alpine sh -c 'apk add --no-cache rsync >/dev/null && rsync -aHAX --numeric-ids --delete /from/ /to/'

    echo ">> Done. Agent ${dst}'s volume now mirrors agent ${src}'s."
    echo ">> Both agents are stopped. Start them with: ./agent.sh up <N>"
}

cmd_export() {
    local id="$1"
    local file="${2:-}"
    require_agent_id "$id"

    # Default export path if not provided.
    if [[ -z "$file" ]]; then
        file="./agent_${id}_export.tar.gz"
    fi

    local vol
    vol="$(volume_name "$id")"

    if ! volume_exists "$vol"; then
        echo "ERROR: Volume '${vol}' does not exist." >&2
        echo "       Agent ${id} has no persistent state to export (was it ever started?)." >&2
        exit 1
    fi

    echo ">> Stopping agent ${id} before export..."
    compose_for_agent "$id" down

    # Resolve the file path to an absolute path so the bind-mount works
    # correctly regardless of the current directory.
    local abs_dir abs_file
    abs_dir="$(cd "$(dirname "$file")" && pwd)"
    abs_file="${abs_dir}/$(basename "$file")"

    local base_name
    base_name="$(basename "$file")"

    echo ">> Exporting volume '${vol}' -> ${abs_file} (max compression)..."
    docker run --rm \
        -v "${vol}:/data:ro" \
        -v "${abs_dir}:/backup" \
        -e "ARCHIVE_NAME=${base_name}" \
        alpine sh -c 'GZIP=-9 tar czf "/backup/${ARCHIVE_NAME}" -C /data .'

    echo ">> Export complete: ${abs_file}"
    echo ">> Agent ${id} is stopped. Start it with: ./agent.sh up ${id}"
}

cmd_import() {
    local file="$1"
    local id="$2"
    require_agent_id "$id"

    if [[ -z "$file" ]]; then
        echo "ERROR: Missing archive file path." >&2
        usage
        exit 1
    fi

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File '${file}' does not exist or is not a regular file." >&2
        exit 1
    fi

    local vol
    vol="$(volume_name "$id")"

    echo "!! WARNING: This will REPLACE all of agent ${id}'s persistent state"
    echo "!!          with the contents of '${file}'."
    echo "!!          Volume '${vol}' will be destroyed and recreated."
    read -r -p "Type 'yes' to confirm importing into agent ${id}: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo ">> Aborted. Nothing was imported."
        exit 0
    fi

    echo ">> Stopping agent ${id} before import..."
    compose_for_agent "$id" down

    # Remove the existing volume (if any) so we start completely fresh.
    if volume_exists "$vol"; then
        echo ">> Removing existing volume '${vol}'..."
        docker volume rm "$vol" >/dev/null
    fi

    echo ">> Creating fresh volume '${vol}'..."
    docker volume create "$vol" >/dev/null

    # Resolve the file path to an absolute path so the bind-mount works.
    local abs_dir abs_file
    abs_dir="$(cd "$(dirname "$file")" && pwd)"
    abs_file="${abs_dir}/$(basename "$file")"

    local base_name
    base_name="$(basename "$file")"

    echo ">> Importing ${abs_file} -> volume '${vol}' ..."
    docker run --rm \
        -v "${vol}:/data" \
        -v "${abs_dir}:/backup:ro" \
        -e "ARCHIVE_NAME=${base_name}" \
        alpine sh -c 'tar xzf "/backup/${ARCHIVE_NAME}" -C /data'

    echo ">> Import complete. Volume '${vol}' now contains the archive contents."
    echo ">> Agent ${id} is stopped. Start it with: ./agent.sh up ${id}"
}

cmd_logs() {
    local id="$1"
    require_agent_id "$id"
    compose_for_agent "$id" logs -f
}

cmd_info() {
    local id="$1"
    require_agent_id "$id"
    print_info "$id"
}

cmd_status() {
    # Discover every agent volume that exists (pattern: agent<N>_agent-root).
    # This tells us which agents have been created, whether running or not.
    local volumes
    volumes="$(docker volume ls --format '{{.Name}}' | grep -E '^agent[0-9]+_agent-root$' | sort -t 'a' -k2 -V)"

    if [[ -z "$volumes" ]]; then
        echo ">> No agent volumes found. No agents have been created yet."
        return
    fi

    # Collect running container names once for fast lookups.
    local running
    running="$(docker ps --filter "name=code-server-agent-" --format '{{.Names}}')"

    # Header
    printf "\n  %-10s  %-6s  %-6s  %-26s  %s\n" "AGENT" "STATUS" "PORT" "VOLUME" "CONTAINER"
    printf "  %-10s  %-6s  %-6s  %-26s  %s\n" "-----" "------" "----" "------" "---------"

    local vol id port container status_text status_color
    for vol in $volumes; do
        # Extract the agent number from the volume name (e.g. agent3_agent-root -> 3).
        id="${vol%%_agent-root}"
        id="${id#agent}"
        port="$(agent_port "$id")"
        container="code-server-agent-${id}"

        if echo "$running" | grep -qx "$container"; then
            status_text="UP"
            status_color="\033[32m"   # green
        else
            status_text="DOWN"
            status_color="\033[31m"   # red
        fi

        printf "  %-10s  ${status_color}%-6s\033[0m  %-6s  %-26s  %s\n" \
            "Agent ${id}" "${status_text}" "${port}" "${vol}" "${container}"
    done
    echo ""
}

# --- Dispatch ----------------------------------------------------------------

COMMAND="${1:-}"
case "$COMMAND" in
    up)      cmd_up "${2:-}" ;;
    down)    cmd_down "${2:-}" ;;
    destroy) cmd_destroy "${2:-}" ;;
    copy)    cmd_copy "${2:-}" "${3:-}" ;;
    export)  cmd_export "${2:-}" "${3:-}" ;;
    import)  cmd_import "${2:-}" "${3:-}" ;;
    logs)    cmd_logs "${2:-}" ;;
    info)    cmd_info "${2:-}" ;;
    status)  cmd_status ;;
    -h|--help|help|"") usage ;;
    *)
        echo "ERROR: Unknown command '$COMMAND'." >&2
        usage
        exit 1
        ;;
esac
