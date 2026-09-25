#!/bin/bash
# Commit edilmemis degisiklikleri (staged, unstaged, untracked), verilen MB limitini
# asmayan parcalar halinde ayri commit'ler olarak kaydeder.
# Kullanim: ./commit-in-chunks.sh [limit_mb] ["commit mesaji"]
# Ornek:    ./commit-in-chunks.sh 5 "Kutuphane dosyalari eklendi"
# Sonra:    ./split-push.sh  (icindeki LIMIT_MB'yi ayni degere cek)

LIMIT_MB=${1:-50}
MSG=${2:-"Toplu commit"}
LIMIT=$((LIMIT_MB*1024*1024))

pause(){ read -p "Devam etmek icin bir tusa basin..."; }
die(){ echo; echo "HATA: $*"; pause; exit 1; }
mb(){ echo $(( ($1+1048575)/1048576 )); }

# --- On kontroller ---
gd=$(git rev-parse --git-dir 2>/dev/null) || die "Bu klasor bir git repo'su degil."
if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -f "$gd/MERGE_HEAD" ]; then
  die "Devam eden rebase/merge var, once onu bitir."
fi

# --- Tum degisiklikleri listele (.gitignore'a uyar), sonra stage'i geri al ---
git add -A || die "git add basarisiz"
tmp=$(mktemp -d)
group=1; cur=0; count=0; total=0; big=0

echo "Degisiklikler analiz ediliyor..."
while IFS= read -r -d '' p; do
  if [ -f "$p" ]; then size=$(wc -c < "$p"); size=${size// /}; else size=0; fi   # silinen dosya = 0
  if [ "$size" -gt $LIMIT ]; then
    echo "  UYARI: $(mb $size) MB, limitten buyuk tek dosya: $p"; big=1
  fi
  if [ $cur -gt 0 ] && [ $((cur+size)) -gt $LIMIT ]; then group=$((group+1)); cur=0; fi
  cur=$((cur+size)); total=$((total+size)); count=$((count+1))
  printf '%s\0' "$p" >> "$tmp/$group"
done < <(git diff --cached --name-only -z --no-renames)

git reset -q

[ $count -eq 0 ] && { rm -rf "$tmp"; die "Commit edilecek degisiklik yok."; }
N=$group

echo
echo "$count dosya, toplam ~$(mb $total) MB -> $N commit (limit ${LIMIT_MB} MB)"
[ $big -eq 1 ] && echo "Not: Limitten buyuk dosyalar tek basina ayri commit olur; bunlarin push'u yine 413 alabilir."
pause

# --- Parca parca commit ---
for ((g=1; g<=N; g++)); do
  git --literal-pathspecs add -A --pathspec-from-file="$tmp/$g" --pathspec-file-nul \
    || die "Parca $g stage edilemedi. Tekrar calistirirsan kalanlardan devam eder."
  git commit -q -m "$MSG" -m "(part $g/$N)" \
    || die "Parca $g commit edilemedi. Tekrar calistirirsan kalanlardan devam eder."
  echo "  $g/$N commit edildi  $(git log -1 --format=%h)"
done
rm -rf "$tmp"

echo
if [ -n "$(git status --porcelain)" ]; then
  echo "UYARI: Commit edilmemis degisiklik kaldi:"
  git status --short
else
  echo "Tamamlandi. Push icin split-push.sh icinde LIMIT_MB=$LIMIT_MB yapip calistir."
fi
pause
