#!/bin/bash
# Buyuk bir push'u HTTP 413 limitine takilmayacak parcalara bolerek gonderir.
# Parcalar gecici branch'lere push edilir, en sonda hedef branch tek adimda guncellenir.

REMOTE="origin"
BRANCH="release/test-release"
LIMIT_MB=64                          # baslangic limiti; 413 gelirse otomatik yariya duser
MIN_MB=1
TMP_NS="refs/heads/tmp/split-push"   # gecici branch prefix'i (branch izinlerine gore degistir)
RUN_ID=$(date +%s)

LIMIT=$((LIMIT_MB*1024*1024))
MIN=$((MIN_MB*1024*1024))
pushed=()
n=0

pause(){ read -p "Devam etmek icin bir tusa basin..."; }
die(){ echo; echo "HATA: $*"; echo "Script'i tekrar calistirirsan kaldigi yerden devam eder."; pause; exit 1; }
mb(){ echo $(( ($1+1048575)/1048576 )); }
desc(){ git log -1 --format='%h %s' "$1"; }

# Bu commit push edilirse gidecek pack boyutu (remote'ta olanlar haric)
pack_size(){
  git rev-list --objects "$1" --not "${pushed[@]}" --remotes="$REMOTE" \
    | git pack-objects --stdout -q 2>/dev/null | wc -c
}

# 0: basarili, 2: 413 alindi (limit dusuruldu, tekrar denenmeli)
push_commit(){
  local c=$1 size=$2 ref out
  n=$((n+1)); ref="$TMP_NS-$RUN_ID-$n"
  echo ">> [$(mb $size) MB] $(desc $c)"
  out=$(git push "$REMOTE" "$c:$ref" 2>&1)
  if [ $? -eq 0 ]; then pushed+=("$c"); return 0; fi
  echo "$out" | tail -5
  if echo "$out" | grep -q "HTTP 413"; then
    LIMIT=$((LIMIT/2))
    [ $LIMIT -lt $MIN ] && die "Limit ${MIN_MB} MB altina dustu, sunucu limiti cok dusuk."
    echo "   413 alindi, limit $(mb $LIMIT) MB'a dusuruldu"
    return 2
  fi
  die "Push basarisiz: $(desc $c)"
}

# tip'e kadar olan first-parent zincirini limit altinda parcalarla push eder.
# Tek basina limiti asan merge commit'lerde merge edilen branch'e recursive iner.
push_chain(){
  local tip=$1
  local -a list parents
  list=($(git rev-list --reverse --first-parent "$tip" --not "${pushed[@]}" --remotes="$REMOTE"))
  local total=${#list[@]} idx=0 lo hi mid s best best_size c p

  while [ $idx -lt $total ]; do
    # Binary search: limit altinda kalan en ileri commit
    lo=$idx; hi=$((total-1)); best=-1
    while [ $lo -le $hi ]; do
      mid=$(( (lo+hi)/2 ))
      s=$(pack_size "${list[$mid]}")
      if [ "$s" -le $LIMIT ]; then best=$mid; best_size=$s; lo=$((mid+1)); else hi=$((mid-1)); fi
    done

    if [ $best -ge 0 ]; then
      push_commit "${list[$best]}" "$best_size" && idx=$((best+1))
      continue
    fi

    # Siradaki tek commit bile limiti asiyor
    c=${list[$idx]}
    parents=($(git rev-list --parents -n1 "$c"))
    if [ ${#parents[@]} -le 2 ]; then
      die "Tek commit limiti asiyor ($(mb $(pack_size $c)) MB): $(desc $c)"
    fi
    echo "Merge commit buyuk, merge edilen branch parcalaniyor: $(desc $c)"
    for p in "${parents[@]:2}"; do push_chain "$p"; done
    s=$(pack_size "$c")
    [ "$s" -le $LIMIT ] || die "Merge commit'in kendisi limiti asiyor ($(mb $s) MB): $(desc $c)"
  done
}

echo "Remote guncelleniyor..."
git fetch "$REMOTE" --prune || die "fetch basarisiz"

total_size=$(pack_size HEAD)
echo "Gonderilecek toplam: ~$(mb $total_size) MB, baslangic limiti: $LIMIT_MB MB"
pause

push_chain HEAD

echo "Hedef branch guncelleniyor: $BRANCH"
git push "$REMOTE" "HEAD:refs/heads/$BRANCH" || die "Hedef branch push basarisiz"

echo "Gecici branch'ler siliniyor..."
del=$(git ls-remote --heads "$REMOTE" | awk -v ns="$TMP_NS-" 'index($2,ns)==1 {print ":"$2}')
[ -n "$del" ] && git push "$REMOTE" $del
git fetch "$REMOTE" --prune >/dev/null 2>&1

echo "Tamamlandi"
pause
