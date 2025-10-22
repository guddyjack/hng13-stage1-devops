# Automated Deployment Script — Stage 1 (HNG DevOps)

This repository contains `deploy.sh` — a single Bash script that automates deploying a Dockerized application to a remote Linux server.

## Features
- Collects repository URL, PAT (optional), branch, remote SSH details, app internal port.
- Clones or pulls the Git repository locally.
- Transfers project files to remote via `rsync`.
- On remote: installs Docker, Docker Compose, Nginx (apt/yum-aware), and configures services.
- Builds and runs containers (supports `docker-compose.yml` or single `Dockerfile`).
- Creates Nginx reverse-proxy config (maps port 80 to your application's internal container port).
- Performs health checks and basic endpoint tests.
- Idempotent: stops/removes previous containers before redeploy.
- Logging to `deploy_YYYYMMDD_HHMMSS.log`.
- `--cleanup` flag to remove deployed resources from remote.

## Usage

1. Make script executable:

```bash
chmod +x deploy.sh
