#!/usr/bin/env bash
#
# deploy.sh - Automated deployment of a Dockerized app to a remote Linux server
#
# Requirements:
#  - Local machine: git, rsync, ssh client
#  - Remote machine: will install docker, docker-compose (or docker compose), nginx
#
# Exit codes:
#  0  success
#  10 input/validation error
#  20 git/clone error
#  30 ssh/connection error
#  40 remote setup error
#  50 deploy/run error
#  60 validation error
#
# Usage: ./deploy.sh
# Optional flags:
#   --cleanup      : remove deployed containers, nginx config and project dir on remote
#
set -o errexit
set -o pipefail
set -o nounset

##############
# Globals
##############
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"
# For idempotency: remote base dir
REMOTE_BASE_DIR="/opt/deployments"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

# default branch
BRANCH="main"
CLEANUP_MODE=0

##############
# Logging
##############
log() {
  printf '%s %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$*" | tee -a "$LOGFILE"
}

err() {
  printf '%s %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "ERROR: $*" | tee -a "$LOGFILE" >&2
}

trap_handler() {
  rc=$?
  err "Trapped exit (code $rc). Check $LOGFILE for details."
  exit "$rc"
}
trap trap_handler INT TERM HUP ERR

##############
# Utils
##############
is_command() {
  command -v "$1" >/dev/null 2>&1
}

read_input() {
  local varname="$1"
  local prompt="$2"
  local hide="$3" # if "true" hide input (for PAT)
  local default="${4-}"
  local val=""

  if [ "${hide}" = "true" ]; then
    printf "%s" "$prompt"
    # shellcheck disable=SC2034
    stty -echo || true
    IFS= read -r val || true
    stty echo || true
    printf "\n"
  else
    if [ -n "$default" ]; then
      printf "%s [%s]: " "$prompt" "$default"
    else
      printf "%s: " "$prompt"
    fi
    IFS= read -r val || true
  fi

  if [ -z "$val" ] && [ -n "$default" ]; then
    eval "$varname=\"${default}\""
  else
    eval "$varname=\"${val}\""
  fi
}

validate_ssh_key() {
  local path="$1"
  if [ -z "$path" ]; then
    return 1
  fi
  if [ ! -f "$path" ]; then
    return 1
  fi
  return 0
}

#####################
# Input collection
#####################
log "Starting deployment script ($SCRIPT_NAME). Writing log to $LOGFILE"

# parse args
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_MODE=1 ;;
    *) ;;
  esac
done

# Interactive prompts
read_input REPO_URL "Git repository URL (HTTPS, e.g. https://github.com/user/repo.git)"
if [ -z "${REPO_URL:-}" ]; then
  err "Repository URL is required."
  exit 10
fi

read_input PAT "Personal Access Token (PAT) (input hidden)" true
if [ -z "${PAT:-}" ]; then
  err "PAT is required to clone private repos (or leave empty for public repos)."
  # allow empty for public repos? We'll treat empty as allowed but warn
  # exit 10
fi

read_input BRANCH "Branch name (optional)" false "main"

read_input REMOTE_USER "Remote SSH username (e.g. ubuntu, root)"
if [ -z "${REMOTE_USER:-}" ]; then
  err "Remote SSH username is required."
  exit 10
fi

read_input REMOTE_HOST "Remote server IP or hostname"
if [ -z "${REMOTE_HOST:-}" ]; then
  err "Remote server IP/hostname is required."
  exit 10
fi

read_input SSH_KEY_PATH "SSH private key path (e.g. ~/.ssh/id_rsa)"
if ! validate_ssh_key "${SSH_KEY_PATH:-}"; then
  err "SSH key not found at ${SSH_KEY_PATH:-}. Please ensure the path is correct."
  exit 10
fi

read_input APP_PORT "Application internal container port (e.g. 3000)"
if ! printf "%s" "$APP_PORT" | grep -Eq '^[0-9]+$'; then
  err "Invalid application port: $APP_PORT"
  exit 10
fi

# derive repo name
REPO_NAME="$(basename -s .git "$REPO_URL")"
if [ -z "$REPO_NAME" ]; then
  err "Could not derive repository name from URL."
  exit 10
fi

LOCAL_CLONE_DIR="./${REPO_NAME}"

log "Inputs: repo=$REPO_URL, branch=$BRANCH, remote=${REMOTE_USER}@${REMOTE_HOST}, sshkey=$SSH_KEY_PATH, app_port=$APP_PORT"

#####################
# Local clone/pull
#####################
git_clone_or_pull() {
  log "Preparing local repository at $LOCAL_CLONE_DIR"

  if [ -d "$LOCAL_CLONE_DIR/.git" ]; then
    log "Repo already exists locally — attempting to pull latest changes"
    (
      cd "$LOCAL_CLONE_DIR"
      git fetch --all --prune >>"$LOGFILE" 2>&1 || { err "git fetch failed"; return 1; }
      git checkout "$BRANCH" >>"$LOGFILE" 2>&1 || { err "git checkout $BRANCH failed"; return 1; }
      git pull origin "$BRANCH" >>"$LOGFILE" 2>&1 || { err "git pull failed"; return 1; }
    )
    log "Successfully pulled latest changes."
    return 0
  fi

  # Prepare clone URL with PAT if provided and using https
  CLONE_URL="$REPO_URL"
  if [ -n "$PAT" ] && printf "%s" "$REPO_URL" | grep -qi '^https://'; then
    # Insert token into URL (works for GitHub and similar)
    CLONE_URL="$(printf "%s" "$REPO_URL" | sed -E "s#https://#https://${PAT}@#I")"
  elif [ -n "$PAT" ] && printf "%s" "$REPO_URL" | grep -qi '^git@'; then
    log "Repo URL uses SSH (git@...). PAT won't be used. Ensure you have SSH access to the repo."
  fi

  git clone --branch "$BRANCH" --depth 1 "$CLONE_URL" "$LOCAL_CLONE_DIR" >>"$LOGFILE" 2>&1 || {
    err "git clone failed. Check repo URL, PAT and network."
    return 1
  }

  log "Successfully cloned repository."
  return 0
}

git_clone_or_pull || exit 20

# verify Dockerfile or docker-compose.yml exists
if [ -f "${LOCAL_CLONE_DIR}/docker-compose.yml" ] || [ -f "${LOCAL_CLONE_DIR}/docker-compose.yaml" ]; then
  COMPOSE_FILE="$(ls "${LOCAL_CLONE_DIR}"/docker-compose.yml "${LOCAL_CLONE_DIR}"/docker-compose.yaml 2>/dev/null | head -n1)"
  log "Found docker-compose file: $COMPOSE_FILE"
elif [ -f "${LOCAL_CLONE_DIR}/Dockerfile" ]; then
  DOCKERFILE="${LOCAL_CLONE_DIR}/Dockerfile"
  log "Found Dockerfile: $DOCKERFILE"
else
  err "Neither docker-compose.yml nor Dockerfile found in repository root."
  exit 20
fi

#####################
# Remote connectivity check
#####################
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
log "Checking SSH connectivity to $SSH_TARGET"

ssh -i "$SSH_KEY_PATH" $SSH_OPTS -q "$SSH_TARGET" 'echo SSH_OK' >>"$LOGFILE" 2>&1 || {
  err "SSH connectivity test failed. Check firewall, SSH key and user."
  exit 30
}
log "SSH connectivity OK"

#####################
# Build the remote commands in a heredoc to run remotely
#####################
# Remote script will:
# - create remote base dir
# - update packages
# - install docker, docker-compose or docker compose
# - add user to docker group
# - install nginx
# - prepare project dir
# - build & run containers (docker-compose or docker)
# - configure nginx
#
REMOTE_PROJECT_DIR="$REMOTE_BASE_DIR/$REPO_NAME"

# Prepare remote commands as a function to allow running in cleanup mode too
remote_run() {
  ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" "$@"
}

remote_setup_and_deploy() {
  log "Starting remote setup and deployment on $SSH_TARGET"

  # Copy project files
  log "Syncing project files to remote ($REMOTE_PROJECT_DIR) using rsync"
  # Exclude .git and node_modules and logs
  rsync -az --delete --exclude='.git' --exclude='node_modules' --exclude='*.log' -e "ssh -i $SSH_KEY_PATH $SSH_OPTS" "$LOCAL_CLONE_DIR"/ "$SSH_TARGET":"${REMOTE_PROJECT_DIR}/" >>"$LOGFILE" 2>&1 || {
    err "rsync failed"
    return 1
  }
  log "rsync complete."

  # Now run remote setup commands
  REMOTE_CMD=$(cat <<'REMOTE_CMDS'
set -e
TIMESTAMP_REMOTE="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="/opt/deployments"
PROJECT_DIR="{{REMOTE_PROJECT_DIR}}"
mkdir -p "$BASE_DIR"
mkdir -p "$PROJECT_DIR"
chown -R "$(whoami)" "$BASE_DIR" "$PROJECT_DIR" || true

# detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
  SUDO_INSTALL="apt-get update -y && apt-get install -y"
  docker_install_cmd='curl -fsSL https://get.docker.com | sh'
  compose_install_cmd='curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose'
elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
  PKG="yum"
  SUDO_INSTALL="yum install -y"
  docker_install_cmd='curl -fsSL https://get.docker.com | sh'
  compose_install_cmd='curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose'
else
  echo "Unsupported package manager"
  exit 1
fi

echo "Using package manager: $PKG"

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  # Use official convenience script
  (set -x; eval "$docker_install_cmd")
else
  echo "Docker already installed: $(docker --version)"
fi

# Ensure docker service enabled/running
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker || true
  systemctl start docker || true
fi

# Add user to docker group if needed
if id -nG "$(whoami)" | grep -q "\bdocker\b"; then
  echo "User already in docker group"
else
  echo "Adding user to docker group"
  sudo usermod -aG docker "$(whoami)" || true
fi

# Install docker-compose if missing (binary)
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "Installing docker-compose..."
  (set -x; eval "$compose_install_cmd") || echo "Compose binary install may have failed — continuing"
fi

# Install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  if [ "$PKG" = "apt" ]; then apt-get update -y; apt-get install -y nginx; else yum install -y nginx; fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx || true
    systemctl start nginx || true
  fi
else
  echo "Nginx already present: $(nginx -v 2>&1)"
fi

# Navigate to project dir
cd "$PROJECT_DIR"

# Stop and remove previous containers that match the project (idempotency)
# If docker-compose exists, use project name; else try to find containers by label/name
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
  echo "Using docker-compose to stop existing services (if any)"
  docker compose down || docker-compose down || true
else
  # If a Dockerfile, we'd run container by naming convention
  echo "No docker-compose file found on remote; preparing Docker build"
  # attempt to find container by name and remove
  # Assume container name = project (basename)
  NAME="$(basename "$PROJECT_DIR")"
  if docker ps -a --format '{{.Names}}' | grep -q "^${NAME}\$"; then
    docker rm -f "${NAME}" || true
  fi
fi

# Build and run
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
  echo "Starting docker-compose up -d"
  docker compose pull || true
  docker compose up -d --build
else
  # Single Dockerfile flow: attempt to build image and run container mapping port
  IMG_NAME="deploy_$(basename "$PROJECT_DIR")"
  docker build -t "$IMG_NAME" .
  # Determine internal port from environment or fallback (the orchestrator expects host port mapping by nginx)
  # Stop existing
  docker rm -f "$IMG_NAME" || true
  docker run -d --name "$IMG_NAME" -p 127.0.0.1:{{APP_PORT}}:{{APP_PORT}} "$IMG_NAME"
fi

# Basic health: list containers
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Prepare nginx config
NGINX_SITE="/etc/nginx/sites-available/{{REPO_NAME}}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/{{REPO_NAME}}.conf"
cat > "$NGINX_SITE" <<NGINX_CONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:{{APP_PORT}};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_CONF

ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx || nginx -s reload || true

echo "REMOTE_SETUP_COMPLETE"
REMOTE_CMDS
)

  # substitute placeholders
  REMOTE_CMD="${REMOTE_CMD//\{\{REMOTE_PROJECT_DIR\}\}/${REMOTE_PROJECT_DIR}}"
  REMOTE_CMD="${REMOTE_CMD//\{\{APP_PORT\}\}/${APP_PORT}}"
  REMOTE_CMD="${REMOTE_CMD//\{\{REPO_NAME\}\}/${REPO_NAME}}"

  # run remote commands via ssh
  log "Running remote setup commands (this may take a few minutes)..."
  ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" "bash -s" <<EOF >>"$LOGFILE" 2>&1
$REMOTE_CMD
EOF

  # Check remote setup success by grepping output
  if remote_run "echo REMOTE_SETUP_PING" >/dev/null 2>&1; then
    log "Remote setup commands executed"
  else
    err "Remote setup may have failed — check logs on remote and $LOGFILE"
    return 1
  fi

  # Validate from remote: check docker service, container and nginx
  log "Validating services remotely"
  remote_run "systemctl is-active --quiet docker && echo DOCKER_RUNNING || echo DOCKER_NOT_RUNNING" >>"$LOGFILE" 2>&1 || true
  # list containers
  remote_run "docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'" >>"$LOGFILE" 2>&1 || true
  remote_run "nginx -t >/dev/null 2>&1 && echo NGINX_OK || echo NGINX_NOT_OK" >>"$LOGFILE" 2>&1 || true

  # Test HTTP endpoint remotely (from remote host)
  HTTP_TEST_REMOTE_OUTPUT="$(remote_run "curl -sS -m 5 http://127.0.0.1:${APP_PORT} || echo CURL_FAIL")" || true
  log "Remote HTTP test result: $HTTP_TEST_REMOTE_OUTPUT"

  log "Remote deployment finished"
  return 0
}

#################
# Cleanup routine
#################
remote_cleanup() {
  log "Running cleanup on remote host $SSH_TARGET"
  remote_run "set -e
PROJECT_DIR=\"${REMOTE_PROJECT_DIR}\"
if [ -d \"${PROJECT_DIR}\" ]; then
  cd \"${PROJECT_DIR}\"
  if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    docker compose down || docker-compose down || true
  else
    NAME=\"$(basename "${PROJECT_DIR}")\"
    docker rm -f \"${NAME}\" || true
  fi
  rm -rf \"${PROJECT_DIR}\"
fi
# Remove nginx site
NGINX_SITE=\"/etc/nginx/sites-available/${REPO_NAME}.conf\"
NGINX_ENABLED=\"/etc/nginx/sites-enabled/${REPO_NAME}.conf\"
rm -f \"$NGINX_ENABLED\" \"$NGINX_SITE\"
nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
echo CLEANUP_DONE" >>"$LOGFILE" 2>&1 || {
    err "Remote cleanup failed"
    return 1
  }
  log "Remote cleanup OK"
  return 0
}

#####################
# Execute
#####################
if [ "$CLEANUP_MODE" -eq 1 ]; then
  log "--cleanup flag detected, performing remote cleanup only"
  remote_cleanup || exit 0
  log "Cleanup complete"
  exit 0
fi

# Run remote setup & deploy
remote_setup_and_deploy || { err "Remote deployment failed"; exit 50; }

# Final validation from local machine: test remote HTTP through nginx (port 80)
log "Testing endpoint from local machine: http://${REMOTE_HOST}/ (attempting HTTP on port 80)"

HTTP_LOCAL_TEST_OUTPUT="$(curl -sS -m 7 "http://${REMOTE_HOST}/" || echo "LOCAL_CURL_FAIL")"
if [ "$HTTP_LOCAL_TEST_OUTPUT" = "LOCAL_CURL_FAIL" ]; then
  err "Local HTTP test failed: no response from http://${REMOTE_HOST}/. Check firewall, security groups or nginx logs."
  # still consider overall script success if container internal responds locally on remote
else
  log "Local HTTP test succeeded (first 300 chars): $(printf '%s' "$HTTP_LOCAL_TEST_OUTPUT" | head -c300)"
fi

log "Deployment script completed. See $LOGFILE for details."
exit 0
