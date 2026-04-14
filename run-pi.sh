#!/usr/bin/env bash
#
# pi-container - Run Pi agent inside a container
#
# Usage:
#   pi-container                         # Start interactive pi in current directory
#   pi-container "Your prompt"           # Run pi with a prompt and exit
#   pi-container --workspace /path       # Use a different host directory as /workspace
#   pi-container --help                  # Show help
#
# Environment Variables:
#   PI_DOCKER_IMAGE - Override default container image (default: pi-agent:latest)
#   PI_API_KEY - Set API key (alternatively use ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
#
# Mounts:
#   - Current / Workspace directory  -> /workspace
#   - ~/.pi                          -> /home/node/.pi
#   - ~/.agents                      -> /home/node/.agents
#   - Note: ~/.npmrc is NOT mounted - host config often has paths that break in container
#

set -euo pipefail

# Configuration
IMAGE="${PI_DOCKER_IMAGE:-pi-agent:latest}"
CONTAINER_NAME="pi-agent-$$"
CONTAINER_ENGINE="${PI_CONTAINER_ENGINE:-podman}"
DEFAULT_AGENT_DIR="/workspace/.pi/agent"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
  cat << EOF
Usage: $(basename "$0") [options] [prompt]

Run Pi agent inside an isolated container with your working directory mounted.

Arguments:
  prompt                    Optional initial prompt to send to pi

Options:
  -h, --help                Show this help message
  -i, --image IMAGE         Container image to use (default: pi-agent:latest)
  -w, --workspace DIR       Use DIR as the host workspace mounted to /workspace
  --no-mount-pi             Don't mount ~/.pi configuration
  --verbose                 Show container commands being executed
  --                        Pass remaining arguments through to pi

Examples:
  $(basename "$0")                                                       # Interactive mode
  $(basename "$0") "List files in src/"                                  # Run with prompt
  pi-container -i my-custom-image "Hello"                                # Custom image
  PI_API_KEY=sk-ant-... $(basename "$0") "Hello"                         # Set API key
  $(basename "$0") -w /path/to/project                                   # Set working Dir
  $(basename "$0") --workspace /path/to/project "Fix the failing tests"  # Set Working dir with prompt
EOF
  exit "${1:-0}"
}

resolve_workspace() {
  local input_dir="${1:-}"

  if [[ -z "$input_dir" ]]; then
    echo -e "${RED}Error: --workspace requires a directory path${NC}" >&2
    exit 1
  fi

  if [[ ! -d "$input_dir" ]]; then
    echo -e "${RED}Error: Workspace directory does not exist: $input_dir${NC}" >&2
    exit 1
  fi

  (
    cd "$input_dir" >/dev/null 2>&1
    pwd -P
  )
}

# Parse arguments
MOUNT_PI=true
VERBOSE=false
PI_ARGS=()
HOST_CWD="$(pwd -P)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -i|--image)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo -e "${RED}Error: --image requires a value${NC}" >&2
        usage 1
      fi
      IMAGE="$2"
      shift 2
      ;;
    -w|--workspace)
      HOST_CWD="$(resolve_workspace "${2:-}")"
      shift 2
      ;;
    --no-mount-pi)
      MOUNT_PI=false
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --)
      shift
      PI_ARGS+=("$@")
      break
      ;;
    -*)
      echo -e "${RED}Error: Unknown option: $1${NC}" >&2
      usage 1
      ;;
    *)
      PI_ARGS+=("$1")
      shift
      ;;
  esac
done

# Get current user info for correct UID/GID in container
USER_UID=$(id -u)
USER_GID=$(id -g)
USER_NAME=$(whoami)
USER_HOME="$HOME"

# Build container run arguments
DOCKER_ARGS=(
  --rm
  --interactive
  --tty
  --name "$CONTAINER_NAME"
  --env "USER=$USER_NAME"
  --env "HOME=/home/node"
  --env "PI_CODING_AGENT_DIR=$DEFAULT_AGENT_DIR"
  --workdir /workspace
  --network host
)

# Podman + SELinux can deny writes to bind mounts unless labeling is configured.
# Disabling container labels for this run avoids EACCES on mounted ~/.pi.
if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
  # Rootless Podman bind mounts require keep-id user namespace mapping for writes.
  DOCKER_ARGS+=(--userns keep-id)
  DOCKER_ARGS+=(--security-opt label=disable)
else
  # Docker does not support --userns keep-id; map UID/GID directly.
  DOCKER_ARGS+=(--user "$USER_UID:$USER_GID")
fi

# Forward relevant environment variables
for env_var in \
  PI_CODING_AGENT_DIR \
  PI_PACKAGE_DIR \
  PI_SKIP_VERSION_CHECK \
  PI_CACHE_RETENTION \
  PI_SHARE_VIEWER_URL \
  ANTHROPIC_API_KEY \
  ANTHROPIC_API_KEY_FILE \
  OPENAI_API_KEY \
  OPENAI_API_KEY_FILE \
  GOOGLE_API_KEY \
  VERTEX_PROJECT \
  VERTEX_LOCATION \
  AZURE_OPENAI_API_KEY \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  AWS_DEFAULT_REGION \
  MISTRAL_API_KEY \
  GROQ_API_KEY \
  CEREBRAS_API_KEY \
  XAI_API_KEY \
  OPENROUTER_API_KEY \
  HF_TOKEN \
  GH_TOKEN \
  GITHUB_TOKEN \
  KIMI_API_KEY \
  MINIMAX_API_KEY \
  KILO_API_TOKEN
do
  if [[ -n "${!env_var:-}" ]]; then
    DOCKER_ARGS+=(--env "$env_var=${!env_var}")
  fi
done

# If GH_TOKEN not set, try to extract it from host gh config using host gh
# (gh stores token in keyring on host, which isn't accessible in container)
# We use 'command -v' from the host to check for gh, not a docker container
if [[ -z "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$GH_TOKEN" ]]; then
      DOCKER_ARGS+=(--env "GH_TOKEN=$GH_TOKEN")
    fi
  fi
fi

# Mount selected workspace directory
DOCKER_ARGS+=(-v "$HOST_CWD:/workspace")

# Recursively find and mount symlinks in a directory
# Args: $1=host_path $2=container_path
# Returns: adds -v arguments for symlinks to DOCKER_ARGS array
collect_symlink_mounts() {
  local host_path="$1"
  local container_path="$2"

  for item in "$host_path"/*; do
    [[ -e "$item" ]] || continue

    local item_name
    item_name="$(basename "$item")"
    local container_item="$container_path/$item_name"

    if [[ -L "$item" ]]; then
      # Symlink: resolve target and mount it
      local target
      target="$(readlink -f "$item")"

      if [[ -d "$target" ]]; then
        DOCKER_ARGS+=(-v "$target:$container_item")
        collect_symlink_mounts "$target" "$container_item"
      elif [[ -f "$target" ]]; then
        DOCKER_ARGS+=(-v "$target:$container_item")
      fi
    elif [[ -d "$item" ]]; then
      # Regular directory: recurse to find nested symlinks
      collect_symlink_mounts "$item" "$container_item"
    fi
    # Regular files don't need special handling
  done
}

# Mount pi configuration directories
if [[ "$MOUNT_PI" == "true" ]]; then
  if [[ -d "$USER_HOME/.pi" ]]; then
    # Optional: mount host ~/.pi for manual access/migration of auth/settings.
    # Pi runtime state defaults to /workspace/.pi/agent unless PI_CODING_AGENT_DIR is overridden.
    DOCKER_ARGS+=(-v "$USER_HOME/.pi:/home/node/.pi")
    collect_symlink_mounts "$USER_HOME/.pi" "/home/node/.pi"
  fi

  # ~/.agents -> /home/node/.agents
  if [[ -d "$USER_HOME/.agents" ]]; then
    DOCKER_ARGS+=(-v "$USER_HOME/.agents:/home/node/.agents:ro")
  fi

  # ~/.gitconfig -> /home/node/.gitconfig
  if [[ -f "$USER_HOME/.gitconfig" ]]; then
    DOCKER_ARGS+=(-v "$USER_HOME/.gitconfig:/home/node/.gitconfig:ro")
  fi

  # ~/.ssh -> /home/node/.ssh (for git operations)
  if [[ -d "$USER_HOME/.ssh" ]]; then
    DOCKER_ARGS+=(-v "$USER_HOME/.ssh:/home/node/.ssh:ro")
  fi

  # ~/.config/gh -> /home/node/.config/gh (GitHub CLI token)
  if [[ -d "$USER_HOME/.config/gh" ]]; then
    DOCKER_ARGS+=(-v "$USER_HOME/.config/gh:/home/node/.config/gh:ro")
  fi
fi

# Show container command if verbose
if [[ "$VERBOSE" == "true" ]]; then
  printf '%bWorkspace:%b %s\n' "$GREEN" "$NC" "$HOST_CWD" >&2
  printf '%bImage:%b %s\n' "$GREEN" "$NC" "$IMAGE" >&2
  printf '%bEngine:%b %s\n' "$GREEN" "$NC" "$CONTAINER_ENGINE" >&2

  printf '%bPi args:%b' "$GREEN" "$NC" >&2
  if [[ ${#PI_ARGS[@]} -eq 0 ]]; then
    printf ' (none)\n' >&2
  else
    printf ' ' >&2
    printf '%q ' "${PI_ARGS[@]}" >&2
    printf '\n' >&2
  fi

  printf '%bContainer args:%b ' "$GREEN" "$NC" >&2
  printf '%q ' "${DOCKER_ARGS[@]}" >&2
  printf '\n' >&2
fi

# Run pi in container through a login shell so ~/.bashrc aliases/functions still load,
# while preserving every pi argument exactly as passed.
exec "$CONTAINER_ENGINE" run "${DOCKER_ARGS[@]}" "$IMAGE" \
  bash -l -c 'pi "$@"' bash "${PI_ARGS[@]}"
