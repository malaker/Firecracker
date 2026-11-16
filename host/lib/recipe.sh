# Recipes: named, ready-to-run tests (change: sandbox-recipes).
# A recipe is a folder with recipe.json (design D2) and its files; folders starting with '_'
# hold shared files and are not recipes.

# FC_RECIPES_DIR is a test override (the smoke suite points it at fixture recipes).
FC_RECIPES="${FC_RECIPES_DIR:-$FC_HOME/recipes}"

# Set by recipe_check_opts; read by cmd_run and write_run_meta.
OPT_RECIPE="" RECIPE_DIR="" RECIPE_KIND="" RECIPE_HOST_FACTS=false RECIPE_META_JSON=null
OPT_SAMPLE="" OPT_PACKAGE="" OPT_RULES="" OPT_ENTRY="" OPT_JSON=0

recipe_names() {
  local d
  for d in "$FC_RECIPES"/*/; do
    d="$(basename "$d")"
    case "$d" in _*|'*') continue ;; esac
    echo "$d"
  done
}

# recipe_manifest_error <name>: prints why the recipe's manifest is invalid; prints nothing when it is valid.
recipe_manifest_error() {
  local name="$1" dir="$FC_RECIPES/$1" f="$FC_RECIPES/$1/recipe.json" err prompt
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "invalid recipe name"; return 0; }
  [ -f "$f" ] || { echo "recipe.json is missing"; return 0; }
  err="$(jq -r '
    def lvl: . == "none" or . == "optional" or . == "required";
    if type != "object" then "the manifest is not a JSON object"
    elif (keys - ["description","kind","image","net","command","prompt","input","require_one_of","timeout","vcpu","mem_mib","host_facts"]) != []
      then "unknown field \((keys - ["description","kind","image","net","command","prompt","input","require_one_of","timeout","vcpu","mem_mib","host_facts"])[0])"
    elif (.description | type) != "string" or .description == "" then "invalid field description"
    elif (.kind != "command" and .kind != "agent") then "invalid field kind (command or agent)"
    elif (.image != "base" and .image != "agent") then "invalid field image (base or agent)"
    elif (.net != "isolated" and .net != "networked") then "invalid field net (isolated or networked)"
    elif .kind == "command" and ((.command | type) != "string" or .command == "" or has("prompt")) then "a command recipe needs command and no prompt"
    elif .kind == "agent" and ((.prompt | type) != "string" or (.prompt | test("^[A-Za-z0-9._-]+$") | not) or has("command")) then "an agent recipe needs prompt (a file name) and no command"
    elif .kind == "agent" and (.image != "agent" or .net != "isolated") then "an agent recipe needs image agent and net isolated"
    elif (.input | type) != "object" or ((.input | keys) - ["sample","package","rules","entry"]) != [] then "invalid field input"
    elif ([.input.sample // "none", .input.package // "none", .input.rules // "none", .input.entry // "none"] | all(lvl) | not) then "invalid field input (each of sample, package, rules, entry is none, optional or required)"
    elif has("require_one_of") and ((.require_one_of | type) != "array" or (.require_one_of - ["sample","package"]) != [] or (.require_one_of | length) != 2) then "invalid field require_one_of"
    elif has("timeout") and ((.timeout | type) != "string" or (.timeout | test("^[1-9][0-9]{0,5}[smh]?$") | not)) then "invalid field timeout"
    elif has("vcpu") and ((.vcpu | type) != "number" or .vcpu < 1 or .vcpu > 32 or .vcpu != (.vcpu | floor)) then "invalid field vcpu"
    elif has("mem_mib") and ((.mem_mib | type) != "number" or .mem_mib < 128 or .mem_mib != (.mem_mib | floor)) then "invalid field mem_mib"
    elif has("host_facts") and ((.host_facts | type) != "boolean") then "invalid field host_facts"
    else "" end' "$f" 2>/dev/null)" || { echo "recipe.json is not valid JSON"; return 0; }
  [ -z "$err" ] || { echo "$err"; return 0; }
  if [ "$(jq -r .kind "$f")" = agent ]; then
    prompt="$(jq -r .prompt "$f")"
    [ -s "$dir/$prompt" ] || echo "the prompt file '$prompt' is missing or empty"
  fi
  return 0
}

# recipe_get <name> <jq-path>: one manifest value ("" when absent).
recipe_get() { jq -r "$2 // empty" "$FC_RECIPES/$1/recipe.json" 2>/dev/null; }

# "sample, [rules]" style summary of what a recipe takes ([..] = optional, a|b = one of).
recipe_inputs_text() {
  jq -r '
    (.require_one_of // []) as $one
    | [ (if ($one | length) > 0 then ($one | join("|")) else empty end),
        (.input | to_entries[] | select(.value != "none") | select(.key as $k | $one | index($k) | not)
         | if .value == "required" then .key else "[\(.key)]" end) ]
    | if length == 0 then "-" else join(", ") end' "$FC_RECIPES/$1/recipe.json"
}

# recipe list [--json]
recipe_list() {
  local n err
  if (( OPT_JSON )); then
    for n in $(recipe_names); do
      err="$(recipe_manifest_error "$n")"
      if [ -n "$err" ]; then
        jq -n --arg n "$n" --arg e "$err" '{name:$n, valid:false, error:$e}'
      else
        jq --arg n "$n" '{name:$n, valid:true, description, kind, image, net,
          input:{sample:(.input.sample // "none"), package:(.input.package // "none"),
                 rules:(.input.rules // "none"), entry:(.input.entry // "none")},
          require_one_of:(.require_one_of // [])}' "$FC_RECIPES/$n/recipe.json"
      fi
    done | jq -s .
    return 0
  fi
  printf '%-15s %-8s %-10s %-22s %s\n' NAME KIND NET INPUT DESCRIPTION
  for n in $(recipe_names); do
    err="$(recipe_manifest_error "$n")"
    if [ -n "$err" ]; then
      printf '%-15s %s\n' "$n" "INVALID: $err"
    else
      printf '%-15s %-8s %-10s %-22s %s\n' "$n" "$(recipe_get "$n" .kind)" "$(recipe_get "$n" .net)" \
        "$(recipe_inputs_text "$n")" "$(recipe_get "$n" .description)"
    fi
  done
}

# Names of recipes with an invalid manifest, for doctor.
recipe_invalid_names() {
  local n
  for n in $(recipe_names); do
    [ -z "$(recipe_manifest_error "$n")" ] || printf '%s ' "$n"
  done
}

# Validates 'recipe <name>' before anything starts (exit 125 via die) and turns the manifest
# into the options an ordinary run uses. Runs before agent_check_opts.
recipe_check_opts() {
  local name="${POSITIONAL[0]:-}" err lvl o t
  [ -n "$name" ] || die "recipe needs a name or 'list' (available: $(recipe_names | tr '\n' ' '))"
  [ "$name" != list ] || return 0
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] && [ -d "$FC_RECIPES/$name" ] \
    || die "unknown recipe '$name' (available: $(recipe_names | tr '\n' ' '))"
  err="$(recipe_manifest_error "$name")"
  [ -z "$err" ] || die "recipe '$name' has an invalid manifest: $err"
  for o in --cmd --payload --net --allow --agent-direct --image --prompt-file; do
    opt_given "$o" && die "$o cannot be used with a recipe: the recipe fixes its command, input folder, image and network mode"
  done
  OPT_RECIPE="$name" RECIPE_DIR="$FC_RECIPES/$name"
  RECIPE_KIND="$(recipe_get "$name" .kind)"
  RECIPE_HOST_FACTS="$(jq -r '.host_facts // false' "$RECIPE_DIR/recipe.json")"
  OPT_NET="$(recipe_get "$name" .net)"
  OPT_IMAGE="$(recipe_get "$name" .image)"
  if ! opt_given --timeout; then
    t="$(recipe_get "$name" .timeout)"; [ -z "$t" ] || OPT_TIMEOUT="$(parse_duration "$t")"
  fi
  if ! opt_given --vcpu; then t="$(recipe_get "$name" .vcpu)"; [ -z "$t" ] || OPT_VCPU="$t"; fi
  if ! opt_given --mem; then t="$(recipe_get "$name" .mem_mib)"; [ -z "$t" ] || OPT_MEM="$t"; fi

  # Inputs: each is none, optional or required.
  local given
  for o in sample package rules entry; do
    lvl="$(jq -r --arg k "$o" '.input[$k] // "none"' "$RECIPE_DIR/recipe.json")"
    case "$o" in sample) given="$OPT_SAMPLE" ;; package) given="$OPT_PACKAGE" ;; rules) given="$OPT_RULES" ;; entry) given="$OPT_ENTRY" ;; esac
    if [ "$lvl" = none ] && [ -n "$given" ]; then die "recipe '$name' takes no $o"; fi
    if [ "$lvl" = required ] && [ -z "$given" ]; then die "recipe '$name' needs a $o (--$o)"; fi
  done
  if [ "$(jq -r '(.require_one_of // []) | length' "$RECIPE_DIR/recipe.json")" != 0 ]; then
    [ -n "$OPT_SAMPLE" ] && [ -n "$OPT_PACKAGE" ] && die "recipe '$name' takes a sample or a package, not both"
    [ -n "$OPT_SAMPLE$OPT_PACKAGE" ] || die "recipe '$name' needs a sample (--sample) or a package (--package)"
  fi
  [ -z "$OPT_SAMPLE" ] || [ -e "$OPT_SAMPLE" ] || die "sample '$OPT_SAMPLE' not found"
  [ -z "$OPT_RULES" ] || [ -d "$OPT_RULES" ] || die "rules folder '$OPT_RULES' not found"
  if [ -n "$OPT_PACKAGE" ]; then
    # A package name with an optional version; never starts with '-', so it cannot become an option.
    local re='^[A-Za-z0-9@][A-Za-z0-9@._/~^<>=!,*+-]{0,199}$'
    [[ "$OPT_PACKAGE" =~ $re ]] \
      || die "invalid package spec '$OPT_PACKAGE' (a package name with an optional version)"
  fi
  if [ -n "$OPT_ENTRY" ]; then
    [ -d "$OPT_SAMPLE" ] || die "--entry only applies to a folder sample"
    local ere='^[A-Za-z0-9._][A-Za-z0-9._/ -]{0,199}$'
    [[ "$OPT_ENTRY" =~ $ere ]] && [[ "/$OPT_ENTRY/" != *"/../"* ]] \
      || die "invalid --entry '$OPT_ENTRY' (a relative path inside the sample folder)"
    [ -f "$OPT_SAMPLE/$OPT_ENTRY" ] || die "entry '$OPT_ENTRY' not found in the sample folder"
  elif [ -d "$OPT_SAMPLE" ] && [ "$(jq -r '.input.entry // "none"' "$RECIPE_DIR/recipe.json")" != none ]; then
    die "a folder sample needs --entry <file> naming the file in it to execute"
  fi

  if [ "$OPT_IMAGE" = agent ] && [ ! -f "$FC_AGENT_ROOTFS" ]; then
    die "recipe '$name' needs the agent image, which is missing; re-run 'fc.ps1 setup' (without -NoAgentImage)"
  fi
  if [ "$RECIPE_KIND" = agent ]; then
    [ -n "$OPT_AGENT" ] || die "recipe '$name' needs an agent profile (--agent; available: $(profile_names))"
    OPT_PROMPT_FILE="$RECIPE_DIR/$(recipe_get "$name" .prompt)"
  else
    [ -z "$OPT_AGENT$OPT_MODEL$OPT_TOKEN_BUDGET" ] || die "recipe '$name' is not an agent recipe; --agent, --model and --token-budget do not apply"
    OPT_CMD="$(recipe_get "$name" .command)"
  fi
  OPT_PAYLOAD="$OPT_SAMPLE"
  RECIPE_META_JSON="$(jq -n --arg n "$name" --arg k "$RECIPE_KIND" \
    --arg s "$( [ -z "$OPT_SAMPLE" ] || basename -- "$OPT_SAMPLE")" --arg p "$OPT_PACKAGE" \
    '{name:$n, kind:$k, sample:(if $s == "" then null else $s end), package:(if $p == "" then null else $p end)}')"
}

# Addresses a probe should test that the guest cannot know by itself (design D7).
recipe_host_facts() {
  local wsl win
  wsl="$(ip -4 -o addr show eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
  win="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  printf 'FC_HOST_WSL=%q\nFC_HOST_WINDOWS=%q\nFC_VM_RANGE=%q\n' "$wsl" "$win" "172.30.0.0/16"
}

# Uploads the recipe's files and the user's input (design D3). Host data is trusted, so the
# guest unpacks it with its own tar. Values go over SSH stdin, never on a command line.
recipe_prepare_guest() {
  local id="$1" kind=none sample=""
  fc_ssh "$id" 'mkdir -p /work/recipe /work/in /work/out /work/.fc' </dev/null || return 1
  tar -C "$RECIPE_DIR" -cf - . | fc_ssh "$id" 'tar -C /work/recipe --no-same-owner -xf -' || return 1
  if [ -d "$FC_RECIPES/_lib" ]; then
    tar -C "$FC_RECIPES" -cf - _lib | fc_ssh "$id" 'tar -C /work/recipe --no-same-owner -xf -' || return 1
  fi
  if [ -d "$OPT_SAMPLE" ]; then
    kind=dir
    tar -C "$OPT_SAMPLE" -cf - . | fc_ssh "$id" 'tar -C /work/in --no-same-owner -xf -' || return 1
  elif [ -n "$OPT_SAMPLE" ]; then
    kind=file sample="$(basename -- "$OPT_SAMPLE")"
    tar -C "$(dirname -- "$OPT_SAMPLE")" -h -cf - -- "$sample" \
      | fc_ssh "$id" 'tar -C /work/in --no-same-owner -xf -' || return 1
  fi
  if [ -n "$OPT_RULES" ]; then
    tar -C "$OPT_RULES" -cf - . | fc_ssh "$id" 'mkdir -p /work/rules && tar -C /work/rules --no-same-owner -xf -' || return 1
  fi
  {
    printf 'FC_RECIPE=%q\nFC_RECIPE_SAMPLE_KIND=%q\nFC_RECIPE_SAMPLE=%q\nFC_RECIPE_PACKAGE=%q\nFC_RECIPE_ENTRY=%q\nFC_RECIPE_RULES=%q\n' \
      "$OPT_RECIPE" "$kind" "$sample" "$OPT_PACKAGE" "$OPT_ENTRY" "$( [ -n "$OPT_RULES" ] && echo 1 || echo 0)"
    [ "$RECIPE_HOST_FACTS" != true ] || recipe_host_facts
  } | fc_ssh "$id" 'cat > /work/.fc/recipe.env' || return 1
}

# recipe <name>|list
cmd_recipe() {
  if [ "${POSITIONAL[0]:-}" = list ]; then recipe_list; return 0; fi
  log "recipe $OPT_RECIPE ($RECIPE_KIND, image $OPT_IMAGE, net $OPT_NET)"
  cmd_run
}
