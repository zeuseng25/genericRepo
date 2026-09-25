#!/bin/bash
# Buyuk bir commit'i, dosyalarini gruplayarak limit altinda birden fazla commit'e boler.
# Kullanim: ./split-commit.sh <commit-hash> [limit_mb]
# Sonra split-push.sh ile push et.

BIG=$1
LIMIT_MB=${2:-50}
LIMIT=$((LIMIT_MB*1024*1024))

pause(){ read -p "Devam etmek icin bir tusa basin..."; }
die(){ echo; echo "HATA: $*"; pause; exit 1; }
mb(){ echo $(( ($1+1048575)/1048576 )); }

[ -z "$BIG" ] && die "Kullanim: ./split-commit.sh <commit-hash> [limit_mb]"
BIG=$(git rev-parse --verify -q "$BIG^{commit}") || die "Commit bulunamadi: $1"

# --- On kontroller ---
git diff --quiet && git diff --cached --quiet || die "Working tree temiz degil, once commit/stash yap."
[ "$(git rev-list --parents -n1 "$BIG" | wc -w)" -eq 2 ] || die "Merge veya root commit desteklenmiyor."
git merge-base --is-ancestor "$BIG" HEAD || die "Commit mevcut branch'in history'sinde degil."
[ -z "$(git rev-list --merges "$BIG"..HEAD)" ] || die "Commit ile HEAD arasinda merge var, rebase merge'leri bozar."

# --- Dosya analizi ve gruplama (uncompressed boyut, yani ihtiyatli) ---
plan=$(mktemp)
group=1; cur=0; too_big=0
echo "Commit: $(git log -1 --format='%h %s' "$BIG")"
echo "En buyuk dosyalar:"
while IFS=$'\t' read -r meta path; do
  sha=$(echo "$meta" | awk '{print $4}')
  if [[ "$sha" =~ ^0+$ ]]; then size=0; else size=$(git cat-file -s "$sha"); fi
  if [ "$size" -gt $LIMIT ]; then
    echo "  !! $(mb $size) MB  $path  (tek dosya limiti asiyor, bolunemez)"; too_big=1
  fi
  if [ $cur -gt 0 ] && [ $((cur+size)) -gt $LIMIT ]; then group=$((group+1)); cur=0; fi
  cur=$((cur+size))
  printf '%s\t%s\t%s\n' "$group" "$size" "$path" >> "$plan"
done < <(git -c core.quotePath=false diff-tree -r --no-renames --no-commit-id "$BIG")

sort -t$'\t' -k2 -nr "$plan" | head -10 | awk -F'\t' '{printf "  %6.1f MB  %s\n", $2/1048576, $3}'
[ $too_big -eq 1 ] && { rm -f "$plan"; die "Limitten buyuk tek dosya var. Bolmek ise yaramaz; dosyayi history'den cikarmak veya proxy limitini arttirmak gerekir."; }

N=$group
[ $N -le 1 ] && { rm -f "$plan"; echo "Commit zaten limit altinda (${LIMIT_MB} MB), bolmeye gerek yok."; pause; exit 0; }
echo "Commit $N parcaya bolunecek (limit ${LIMIT_MB} MB)."
pause

# --- Yedek ---
backup="backup/before-split-$(date +%s)"
git branch "$backup" || die "Yedek branch olusturulamadi"
echo "Yedek branch: $backup"

# --- Rebase: sadece hedef commit'te dur ---
GIT_SEQUENCE_EDITOR="sed -i -E 's/^(p|pick) (${BIG:0:7}[0-9a-f]*)/edit \2/'" \
  git rebase -i "$BIG^" >/dev/null 2>&1
[ "$(git rev-parse HEAD)" = "$BIG" ] || { git rebase --abort 2>/dev/null; die "Rebase hedef commit'te durmadi."; }

AUTHOR=$(git log -1 --format='%an <%ae>' "$BIG")
DATE=$(git log -1 --format='%aD' "$BIG")
MSG=$(git log -1 --format='%B' "$BIG")

git reset -q HEAD~1   # degisiklikler working tree'de kalir

for ((g=1; g<=N; g++)); do
  while IFS=$'\t' read -r grp size path; do
    [ "$grp" -eq $g ] && git add -A -- "$path"
  done < "$plan"
  git commit -q --author="$AUTHOR" --date="$DATE" -m "$MSG" -m "(part $g/$N)" \
    || { git rebase --abort; die "Parca $g commit edilemedi, rebase geri alindi."; }
  echo "  parca $g/$N commit edildi"
done
rm -f "$plan"

# Parcalarin toplami orijinal commit ile ayni tree'yi vermeli
git diff --quiet "$BIG" HEAD || { git rebase --abort; die "Bolunmus sonuc orijinalle uyusmuyor, rebase geri alindi."; }

GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || die "Rebase --continue basarisiz. Geri donmek icin: git rebase --abort"

# Final dogrulama
if git diff --quiet "$backup" HEAD; then
  echo "Tamamlandi. Son durum orijinalle birebir ayni."
  echo "Geri almak istersen: git reset --hard $backup"
else
  echo "UYARI: Final tree yedekten farkli! Kontrol et: git diff $backup HEAD"
fi
pause
