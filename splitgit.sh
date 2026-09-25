#!/bin/bash
# Buyuk bir commit'i limit altinda birden fazla commit'e boler.
# Working tree'ye dokunmaz: orijinal blob'lari dogrudan kullanir (git plumbing).
# autocrlf, .gitignore, filemode, buyuk/kucuk harf gibi Windows sorunlarindan etkilenmez.
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
[ "$(git rev-list --parents -n1 "$BIG" | wc -w)" -eq 2 ] || die "Merge veya root commit desteklenmiyor."
git merge-base --is-ancestor "$BIG" HEAD || die "Commit mevcut branch'in ($branch) history'sinde degil."
[ -z "$(git rev-list --merges "$BIG"..HEAD)" ] || die "Commit ile HEAD arasinda merge var."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Dosya analizi ve gruplama ---
metas=(); paths=(); groups=(); sizes=()
group=1; cur=0; too_big=0
echo "Branch: $branch"
echo "Commit: $(git log -1 --format='%h %s' "$BIG")"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  sha=$(echo "$meta" | awk '{print $4}')
  if [[ "$sha" =~ ^0+$ ]]; then size=0; else size=$(git cat-file -s "$sha"); fi
  if [ "$size" -gt $LIMIT ]; then
    echo "  !! $(mb $size) MB  $path  (tek dosya limiti asiyor)"; too_big=1
  fi
  if [ $cur -gt 0 ] && [ $((cur+size)) -gt $LIMIT ]; then group=$((group+1)); cur=0; fi
  cur=$((cur+size))
  metas+=("$meta"); paths+=("$path"); groups+=("$group"); sizes+=("$size")
done < <(git diff-tree -r -z --no-renames --no-commit-id "$BIG")

echo "En buyuk dosyalar:"
for i in "${!paths[@]}"; do printf '%s\t%s\n' "${sizes[$i]}" "${paths[$i]}"; done \
  | sort -nr | head -10 | awk -F'\t' '{printf "  %6.1f MB  %s\n", $1/1048576, $2}'
[ $too_big -eq 1 ] && die "Limitten buyuk tek dosya var, limiti o dosyanin ustune cek."

N=$group
[ $N -le 1 ] && { echo "Commit zaten limit altinda, bolmeye gerek yok."; pause; exit 0; }
ORIG=$(git rev-parse HEAD)
rest=$(git rev-list --count "$BIG"..HEAD)
echo "${#paths[@]} dosya, $N parcaya bolunecek (limit ${LIMIT_MB} MB), sonrasindaki $rest commit yeniden yazilacak."
pause

# Orijinal commit'in author/committer bilgisiyle commit olustur
make_commit(){  # $1=tree $2=parent $3=kaynak commit $4=mesaj dosyasi
  GIT_AUTHOR_NAME=$(git log -1 --format=%an "$3") \
  GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$3") \
  GIT_AUTHOR_DATE=$(git log -1 --format=%ad --date=raw "$3") \
  GIT_COMMITTER_NAME=$(git log -1 --format=%cn "$3") \
  GIT_COMMITTER_EMAIL=$(git log -1 --format=%ce "$3") \
  GIT_COMMITTER_DATE=$(git log -1 --format=%cd --date=raw "$3") \
  git commit-tree "$1" -p "$2" -F "$4"
}

# --- Parcalari gecici bir index uzerinde olustur ---
export GIT_INDEX_FILE="$tmp/index"
git read-tree "$BIG^" || die "read-tree basarisiz"
parent=$(git rev-parse "$BIG^")

for ((g=1; g<=N; g++)); do
  : > "$tmp/entries"
  for i in "${!paths[@]}"; do
    [ "${groups[$i]}" -eq $g ] || continue
    read -r _ newmode _ newsha status <<< "${metas[$i]}"
    if [ "${status:0:1}" = "D" ]; then
      printf '0 %s 0\t%s\0' "$newsha" "${paths[$i]}" >> "$tmp/entries"
    else
      printf '%s %s 0\t%s\0' "$newmode" "$newsha" "${paths[$i]}" >> "$tmp/entries"
    fi
  done
  git update-index -z --index-info < "$tmp/entries" || die "Parca $g index'e yazilamadi"
  tree=$(git write-tree) || die "Parca $g tree olusturulamadi"
  { git log -1 --format=%B "$BIG"; echo; echo "(part $g/$N)"; } > "$tmp/msg"
  parent=$(make_commit "$tree" "$parent" "$BIG" "$tmp/msg") || die "Parca $g commit edilemedi"
  echo "  parca $g/$N  $(git rev-parse --short "$parent")"
done
unset GIT_INDEX_FILE

[ "$(git rev-parse "$parent^{tree}")" = "$(git rev-parse "$BIG^{tree}")" ] \
  || die "Parcalarin toplami orijinal commit ile uyusmuyor (branch degistirilmedi)"

# --- Sonraki commit'leri ayni tree'lerle yeniden yaz ---
for c in $(git rev-list --reverse "$BIG..$ORIG"); do
  git log -1 --format=%B "$c" > "$tmp/msg"
  parent=$(make_commit "$(git rev-parse "$c^{tree}")" "$parent" "$c" "$tmp/msg") \
    || die "Commit yeniden yazilamadi: $(git log -1 --format='%h %s' "$c")"
done

[ "$(git rev-parse "$parent^{tree}")" = "$(git rev-parse "$ORIG^{tree}")" ] \
  || die "Son durum orijinalle uyusmuyor (branch degistirilmedi)"

# --- Yedek al ve branch'i tasi ---
backup="backup/before-split-$(date +%s)"
git branch "$backup" "$ORIG" || die "Yedek branch olusturulamadi"
git update-ref -m "split-commit" "refs/heads/$branch" "$parent" "$ORIG" || die "Branch guncellenemedi"
git update-index -q --refresh >/dev/null 2>&1

echo
echo "Tamamlandi. Son durum orijinalle birebir ayni, working tree'ye dokunulmadi."
echo "Yedek: $backup   Geri almak icin: git reset --hard $backup"
pause
