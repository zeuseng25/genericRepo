cd /path/to/agent-coder && git pull

# 1) CI'ın bitmesini bekleyin — imajlar main'e push'ta yayınlanıyor.
#    Yeşil olduğunu görmeden çekerseniz eski imajı alırsınız.
gh run list --workflow=release-images.yml --limit 3

# 2) Runner imajları — İKİSİ DE. `:latest` sürümlü etiketi tazelemez.
docker pull ghcr.io/codeeer/agent-coder-runner:latest
docker pull ghcr.io/codeeer/agent-coder-runner:node-24.13.0

# 3) Backend ve frontend
RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml pull

# 4) Ayağa kaldır
APP_NAME="Şirket AI" \
RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest \
BACKEND_IMAGE=ghcr.io/codeeer/agent-coder-backend:latest \
FRONTEND_IMAGE=ghcr.io/codeeer/agent-coder-frontend:latest \
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml up -d --force-recreate

