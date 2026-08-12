MSYS_NO_PATHCONV=1 docker exec $id sh -c '
  d=/home/agent/.local/share/opencode
  while true; do
    find $d -name "*.json" -newermt "-3 seconds" 2>/dev/null \
      -exec sh -c "echo \"--- {} ---\"; cat {}" \;
    sleep 2
  done'
