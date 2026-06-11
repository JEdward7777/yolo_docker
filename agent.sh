#!/bin/bash
#
# agent.sh - Manage stateful code-server agent containers.
#
# Each agent is an isolated code-server instance with its own persistent
# OverlayFS-backed root volume (agentN_agent-root). Agent N listens on port
# 8440 + N by default (agent 1 -> 8441, agent 2 -> 8442, ...).
#
# Usage:
#   ./agent.sh up      <N>   Build (if needed) and start agent N
#   ./agent.sh down    <N>   Stop & remove agent N's container (state PRESERVED)
#   ./agent.sh destroy <N>   Stop, remove, and WIPE agent N's persistent volume
#   ./agent.sh logs    <N>   Follow logs for agent N
#   ./agent.sh status        Show all running agents
#   ./agent.sh info    <N>   Show connection info for agent N
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
  up      <N>   Build (if needed) and start agent N in the background.
  down    <N>   Stop and remove agent N's container. Persistent state is KEPT.
  destroy <N>   Stop, remove, and DELETE agent N's persistent volume (full reset).
  logs    <N>   Follow the logs for agent N.
  info    <N>   Print connection details for agent N.
  status        List all running agent containers.

Examples:
  ./agent.sh up 1        # start agent 1 on port 8441
  ./agent.sh up 2        # start agent 2 on port 8442
  ./agent.sh down 1      # stop agent 1, keep its files
  ./agent.sh destroy 1   # nuke agent 1's state for a fresh project
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
    echo ">> Running agent containers:"
    docker ps --filter "name=code-server-agent-" \
        --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"
}

# --- Dispatch ----------------------------------------------------------------

COMMAND="${1:-}"
case "$COMMAND" in
    up)      cmd_up "${2:-}" ;;
    down)    cmd_down "${2:-}" ;;
    destroy) cmd_destroy "${2:-}" ;;
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
