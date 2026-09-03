curl -s $LLM_URL/v1/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"<model-adin>","max_tokens":40,
       "prompt":"<|fim_prefix|>fun topla(a: Int, b: Int): Int {\n    return <|fim_suffix|>\n}<|fim_middle|>"}'
