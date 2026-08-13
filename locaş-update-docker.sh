RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest docker compose \
  --project-directory . -f deploy/docker-compose.yml pull
… up -d --force-recreate
