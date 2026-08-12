docker pull ghcr.io/codeeer/agent-coder-runner:latest

RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml pull

RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml up -d --force-recreate
