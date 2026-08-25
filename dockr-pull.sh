cd /path/to/agent-coder
git pull

# ─── 1) Yayının bittiğini görün ──────────────────────────────────────────────
# İmajlar main'e push'ta yayınlanıyor. CI koşarken çekerseniz ESKİ imajı
# alırsınız ve hiçbir şey bunu size söylemez.
gh run list --workflow=release-images.yml --limit 3
# (gh yoksa: GitHub → Actions → release-images yeşil mi)

# ─── 2) .env'i kalıcı yap ────────────────────────────────────────────────────
# Satır-içi değişken yalnızca o komut için geçerli; sonraki `restart` yerel
# imaja döner. RUNNER_IMAGE ayrıca SÜRÜMLÜ etiketin nereden geleceğini de
# belirliyor (ghcr base → ghcr node-*, yerel base → yerel node-*).
grep -q '^RUNNER_IMAGE=' .env \
  && sed -i.bak 's|^RUNNER_IMAGE=.*|RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest|' .env \
  || echo 'RUNNER_IMAGE=ghcr.io/codeeer/agent-coder-runner:latest' >> .env

grep -q '^APP_NAME=' .env || echo 'APP_NAME=Şirket AI' >> .env
rm -f .env.bak

grep -E '^(RUNNER_IMAGE|APP_NAME)=' .env    # gerçekten yazıldı mı

# ─── 3) Runner imajları — İKİSİ DE ───────────────────────────────────────────
# `:latest` sürümlü etiketi tazelemez; koşu Node sürümü seçiliyse onu kullanır.
docker pull ghcr.io/codeeer/agent-coder-runner:latest
docker pull ghcr.io/codeeer/agent-coder-runner:node-24.13.0

# ─── 4) Backend + frontend çek ve kaldır ─────────────────────────────────────
# Önek yok: RUNNER_IMAGE artık .env'de, backend/frontend varsayılanı zaten GHCR.
# `-f docker-compose.ghcr.yml` HER çağrıda gerekli — yoksa yerelden derlemeye
# kalkar.
docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml pull

docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml up -d --force-recreate

# ─── 5) Doğrulama — "çektim" yeterli değil ───────────────────────────────────
for t in latest node-24.13.0; do
  printf "kilit %-14s " "$t"
  docker run --rm --entrypoint sh ghcr.io/codeeer/agent-coder-runner:$t \
    -c 'grep -q nameMapper=file-gav /opt/maven/bin/mvn && echo VAR || echo YOK'
done

curl -s -o /dev/null -w "backend yeni uç : %{http_code}\n" \
  http://localhost:8080/api/dependency-cache

docker compose --project-directory "$PWD" \
  -f deploy/docker-compose.yml -f deploy/docker-compose.ghcr.yml ps
