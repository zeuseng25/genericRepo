while true; do
  id=$(docker ps --format '{{.ID}} {{.Image}}' | grep -i "runner\|opencode" | awk '{print $1}' | head -1)
  if [ -n "$id" ]; then
    echo "=== runner: $id — agent akisi izleniyor ==="
    MSYS_NO_PATHCONV=1 docker exec $id sh -c '
      d=/home/agent/.local/share/opencode
      while true; do
        find $d -name "*.json" -newermt "-3 seconds" 2>/dev/null \
          -exec sh -c "echo \"--- {} ---\"; cat {}" \;
        sleep 2
      done'
    break
  fi
  sleep 0.3
done
