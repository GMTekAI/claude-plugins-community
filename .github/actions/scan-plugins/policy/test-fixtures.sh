#!/usr/bin/env bash
# Runs each fixture in fixtures/ through the same `claude -p` invocation that
# scan.sh uses, then asserts the structured output matches the fixture's
# expected.json. Catches calibration drift on prompt + schema edits.
#
# Usage: ANTHROPIC_API_KEY=... bash policy/test-fixtures.sh
# Exit 0 = all pass; 1 = assertion failure; 2 = invocation error.

set -euo pipefail

POLICY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$POLICY_DIR/prompt.md"
SCHEMA_FILE="$POLICY_DIR/schema.json"
EXPECTED_SCHEMA="$POLICY_DIR/expected.schema.json"
FIXTURES_DIR="$POLICY_DIR/fixtures"

for f in "$PROMPT_FILE" "$SCHEMA_FILE" "$EXPECTED_SCHEMA"; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
[[ -d "$FIXTURES_DIR" ]]          || { echo "missing $FIXTURES_DIR" >&2; exit 2; }
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "ANTHROPIC_API_KEY not set" >&2; exit 2; }
command -v claude  >/dev/null || { echo "claude CLI not on PATH" >&2; exit 2; }
command -v jq      >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 2; }
python3 -c 'import jsonschema' 2>/dev/null || { echo "pip install jsonschema" >&2; exit 2; }

echo "Validating fixture expected.json files against $(basename "$EXPECTED_SCHEMA")..."
python3 - "$EXPECTED_SCHEMA" "$FIXTURES_DIR" <<'PY' || exit 1
import json, sys, glob
from pathlib import Path
import jsonschema
schema = json.load(open(sys.argv[1]))
jsonschema.Draft7Validator.check_schema(schema)
v = jsonschema.Draft7Validator(schema)
errors = checked = 0
for d in sorted(glob.glob(str(Path(sys.argv[2]) / "*"))):
    p = Path(d) / "expected.json"
    if not p.exists(): continue
    checked += 1
    try: data = json.load(open(p))
    except json.JSONDecodeError as e:
        print(f"  {p}: invalid JSON — {e}", file=sys.stderr); errors += 1; continue
    for err in v.iter_errors(data):
        path = ".".join(str(x) for x in err.absolute_path) or "<root>"
        print(f"  {p}: at {path}: {err.message}", file=sys.stderr); errors += 1
if errors:
    print(f"  {errors} schema error(s) across {checked} fixture(s)", file=sys.stderr); sys.exit(1)
print(f"  {checked} fixture(s) validated cleanly.")
PY
echo

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
schema="$(cat "$SCHEMA_FILE")"
prompt="$(cat "$PROMPT_FILE")"$'\n\n'"The plugin files are in the current working directory. Read every relevant file before deciding."

failures=0; total=0
for fixture in "$FIXTURES_DIR"/*/; do
  name="$(basename "$fixture")"
  expected="$fixture/expected.json"
  [[ -f "$expected" ]] || { echo "SKIP $name (no expected.json)"; continue; }
  total=$((total+1))
  echo "===== $name ====="

  rm -rf "$STAGE/repo"; cp -r "$fixture" "$STAGE/repo"; rm -f "$STAGE/repo/expected.json"

  result="$STAGE/$name.json"
  if ! (cd "$STAGE/repo" && claude -p "$prompt" \
        --bare --allowed-tools "Read,Glob,Grep" \
        --output-format json --json-schema "$schema" \
        </dev/null) > "$result" 2> "$STAGE/$name.err"; then
    echo "  FAIL: claude exited non-zero"; sed 's/^/    /' "$STAGE/$name.err" | head -5
    failures=$((failures+1)); continue
  fi

  so="$(jq -c '.result // .structured_output // {}' "$result")"
  if [[ "$so" == "{}" ]]; then
    echo "  FAIL: no structured output"; failures=$((failures+1)); continue
  fi

  asserts="$(jq -c '.assertions' "$expected")"
  ok=1
  for key in passes claims_unaffiliated_brand brand_claimed may_make_external_network_calls may_download_additional_software; do
    jq -e "has(\"$key\")" <<<"$asserts" >/dev/null || continue
    if ! jq -e "has(\"$key\")" <<<"$so" >/dev/null; then
      echo "  FAIL $key: missing from output"; ok=0; continue
    fi
    exp="$(jq -r ".$key" <<<"$asserts")"; act="$(jq -r ".$key" <<<"$so")"
    [[ "$exp" == "$act" ]] || { echo "  FAIL $key: expected='$exp' actual='$act'"; ok=0; }
  done
  if jq -e 'has("violations_must_contain")' <<<"$asserts" >/dev/null; then
    needle="$(jq -r '.violations_must_contain' <<<"$asserts")"
    hay="$(jq -r '.violations // ""' <<<"$so")"
    grep -qi -- "$needle" <<<"$hay" || { echo "  FAIL violations missing '$needle'"; echo "    actual: $hay" | head -c 200; echo; ok=0; }
  fi

  if [[ "$ok" == 1 ]]; then echo "  PASS"
  else failures=$((failures+1)); echo "  output:"; jq . <<<"$so" | sed 's/^/    /'; fi
done

echo; echo "===== $((total-failures))/$total passed ====="
[[ "$failures" -eq 0 ]]
