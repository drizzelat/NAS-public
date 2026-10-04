# Per-turn token meter for a `claude -p --output-format stream-json --verbose` stream.
# Usage: jq -nrR -f .github/scripts/claude-turn-meter.jq claude.jsonl | column -t -s $'\t'
[inputs | fromjson? // empty] as $ev
| ([$ev[] | select(.type == "user") | .message.content[]?
    | select(.type? == "tool_result" and (.tool_use_id | type) == "string")
    | {key: .tool_use_id,
       value: (.content | if type == "string" then length
               elif type == "array" then ([.[] | .text? // "" | length] | add // 0)
               else 0 end)}]
   | from_entries) as $res
# One API call streams one assistant event per content block under one message id, and their
# output_tokens is a start-of-message snapshot, so output per turn comes from thinking_tokens.
| (reduce $ev[] as $e ({order: [], by: {}, think: 0};
    if $e.type == "system" and $e.subtype == "thinking_tokens" then
      .think = ([.think, ($e.estimated_tokens // 0)] | max)
    elif $e.type == "assistant" and ($e.message.id | type) == "string" then
      $e.message.id as $id
      | (if .by[$id] == null then .order += [$id] | .by[$id] = {tools: [], think: .think} | .think = 0
         else . end)
      | .by[$id].usage = $e.message.usage
      | .by[$id].tools += [$e.message.content[]? | select(.type? == "tool_use")]
    else . end)) as $t
| ["turn", "context", "cache_write", "thinking_estimate", "result_chars", "tool", "input"],
  ($t.order | to_entries[] | .key as $n | $t.by[.value] as $m | ($m.usage // {}) as $u
   | [$n + 1,
      ([$u.input_tokens, $u.cache_read_input_tokens, $u.cache_creation_input_tokens] | map(. // 0) | add),
      ($u.cache_creation_input_tokens // 0),
      $m.think,
      ([$m.tools[] | $res[.id] // 0] | add // 0),
      ([$m.tools[].name] | join("+")),
      ([$m.tools[].input | .command // .file_path // .pattern // tojson]
       | join(" ;; ") | gsub("\\s+"; " ") | .[0:240])])
| @tsv
