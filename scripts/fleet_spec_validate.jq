def fleet_spec_v1:
  if type == "object" and
     ((keys - ["agent", "schema_version", "taskset", "workers"]) | length == 0) and
     (.schema_version == 1) and
     (.taskset | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
     ((has("agent") | not) or
       (.agent | type == "string" and length > 0 and (test("[[:cntrl:]]") | not))) and
     # Prompt mode's JSON Schema says integer, but JSON/jq represents both 3 and
     # 3.0 as numbers. Deliberately accept integral values here, then normalize
     # them so downstream shell arithmetic always receives an integer.
     ((has("workers") | not) or
       (.workers | type == "number" and . > 0 and . == floor and . <= 4096))
  then {schema_version, taskset}
    + (if has("agent") then {agent} else {} end)
    + (if has("workers") then {workers: (.workers | floor)} else {} end)
  else error("invalid FleetSpec") end;
