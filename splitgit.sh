#!/bin/bash
# Buyuk bir commit'i, dosyalarini gruplayarak limit altinda birden fazla commit'e boler.
# Rebase -i kullanmaz: commit'i acar, parcalar, sonraki commit'leri cherry-pick eder.
# Kullanim: bash split-commit.sh <commit-hash> [limit_mb]

BIG=$1
LIMIT_MB=${2:-50}
LIMIT=$((LIMIT_MB*1024*1024))

pause(){ read -p "Devam etmek icin bir tusa basin..."; }
die(){ echo; echo "HATA: $*"; pause; exit 1; }
mb(){ echo $(( ($1+1048575)/1048576 )); }

[ -z "$BIG" ] && die "Kullanim: bash split-commit.sh <commit-hash> [limit_mb]"
BIG=$(git rev-parse --verify -q "$BIG^{commit}") || die "Commit bulunamadi: $1"

# --- On kontroller ---
branch=$(git symbolic-ref --short -q HEAD) || die "Detached HEAD durumundasin, once branch'e gec."
gd=$(git rev-parse --git-dir)
if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -f "$gd/CHERRY_PICK_HEAD" ]; then
  die "Yarim kalmis rebase/cherry-pick var. Once: git rebase --abort  veya  git cherry-pick --abort"
fi
git diff --quiet && git diff --cached --quiet || die "Working tree temiz degil, once commit/stash yap."
[ "$(git rev-list --parents -n1 "$BIG" | wc -w)" -eq 2 ] || die "Merge veya root commit desteklenmiyor."
git merge-base --is-ancestor "$BIG" HEAD || die "Commit mevcut branch'in ($branch) history'sinde degil."
[ -z "$(git rev-list --merges "$BIG"..HEAD)" ] || die "Commit ile HEAD arasinda merge var."

# --- Dosya analizi ve gruplama ---
plan=$(mktemp)
group=1; cur=0; too_big=0
echo "Branch: $branch"
echo "Commit: $(git log -1 --format='%h %s' "$BIG")"
while IFS=$'\t' read -r meta path; do
  sha=$(echo "$meta" | awk '{print $4}')
  if [[ "$sha" =~ ^0+$ ]]; then size=0; else size=$(git cat-file -s "$sha"); fi
  if [ "$size" -gt $LIMIT ]; then
    echo "  !! $(mb $size) MB  $path  (tek dosya limiti asiyor)"; too_big=1
  fi
  if [ $cur -gt 0 ] && [ $((cur+size)) -gt $LIMIT ]; then group=$((group+1)); cur=0; fi
  cur=$((cur+size))
  printf '%s\t%s\t%s\n' "$group" "$size" "$path" >> "$plan"
done < <(git -c core.quotePath=false diff-tree -r --no-renames --no-commit-id "$BIG")

echo "En buyuk dosyalar:"
sort -t$'\t' -k2 -nr "$plan" | head -10 | awk -F'\t' '{printf "  %6.1f MB  %s\n", $2/1048576, $3}'
[ $too_big -eq 1 ] && { rm -f "$plan"; die "Limitten buyuk tek dosya var, limiti o dosyanin ustune cek."; }

N=$group
[ $N -le 1 ] && { rm -f "$plan"; echo "Commit zaten limit altinda, bolmeye gerek yok."; pause; exit 0; }
rest=$(git rev-list --count "$BIG"..HEAD)
echo "Commit $N parcaya bolunecek (limit ${LIMIT_MB} MB), sonrasindaki $rest commit yeniden uygulanacak."
pause

# --- Yedek ---
ORIG=$(git rev-parse HEAD)
backup="backup/before-split-$(date +%s)"
git branch "$backup" || die "Yedek branch olusturulamadi"
echo "Yedek branch: $backup"

# Hata olursa branch'e dokunulmamis halde geri don
rollback(){
  git cherry-pick --abort >/dev/null 2>&1
  git checkout -q -f "$branch"
  rm -f "$plan"
  die "$1 (Branch degismedi, yedek: $backup)"
}

# --- Commit'i ac ---
git checkout -q --detach "$BIG" || rollback "Commit'e gecilemedi"
git reset -q HEAD~1 || rollback "reset basarisiz"

AUTHOR=$(git log -1 --format='%an <%ae>' "$BIG")
DATE=$(git log -1 --format='%aD' "$BIG")
MSG=$(git log -1 --format='%B' "$BIG")

for ((g=1; g<=N; g++)); do
  while IFS=$'\t' read -r grp size path; do
    [ "$grp" -eq $g ] && git add -A -- "$path"
  done < "$plan"
  git commit -q --author="$AUTHOR" --date="$DATE" -m "$MSG" -m "(part $g/$N)" \
    || rollback "Parca $g commit edilemedi"
  echo "  parca $g/$N commit edildi"
done
rm -f "$plan"

git diff --quiet "$BIG" HEAD || rollback "Parcalarin toplami orijinal commit ile uyusmuyor"

# --- Sonraki commit'leri yeniden uygula ---
if [ "$rest" -gt 0 ]; then
  echo "Sonraki $rest commit uygulaniyor..."
  git cherry-pick --allow-empty --keep-redundant-commits "$BIG..$ORIG" >/dev/null \
    || rollback "cherry-pick basarisiz"
fi

git diff --quiet "$ORIG" HEAD || rollback "Son durum orijinalle uyusmuyor"

# --- Branch'i yeni history'ye tasi ---
git checkout -q -B "$branch" || rollback "Branch guncellenemedi"

echo
echo "Tamamlandi. Son durum orijinalle birebir ayni."
echo "Geri almak istersen: git reset --hard $backup"
pause
