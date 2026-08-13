cd /Users/omer/workspaces/ai/agent-coder

# 1) Runner ve node sürümlü etiketleri — bunlar compose servisi DEĞİL,
#    `compose pull` onları görmez.
docker pull ghcr.io/codeeer/agent-coder-runner:latest
docker pull ghcr.io/codeeer/agent-coder-runner:node-24.13.0

# 2) .env'e yaz — yoksa sonraki `restart` yerel imaja döner.
sed -i.bak 's|^RUNNER_IMAGE=.*|RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest|' .env && rm -f .env.bak

# 3) Backend + frontend imajlarını çek (ghcr KATMANI şart).
RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml pull

# 4) Ayağa kaldır — aynı üç değişkenle.
RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml up -d --force-recreate
