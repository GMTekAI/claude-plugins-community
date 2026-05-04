# Policy

Files here configure the Claude policy reviewer used by `../scripts/scan.sh`.

| File | Purpose |
|---|---|
| `prompt.md` | The reviewer prompt. Edit this to change policy everywhere. |
| `schema.json` | JSON Schema for the structured verdict the reviewer must return. |
| `expected.schema.json` | Schema for fixture `expected.json` files (typo guard). |
| `fixtures/` | Mini-plugins + expected verdicts for regression testing. |
| `test-fixtures.sh` | Runs every fixture through `claude -p` and asserts the verdict. |

## Fixtures

Each `fixtures/<name>/` is a self-contained mini-plugin with an `expected.json`.
Current set:

| Fixture | Validates |
|---|---|
| `legit-indie-pdf-tools` | Negative — generic name, must pass |
| `bare-brand-claim-stripe` | Positive — bare brand 'stripe', indie author, must trip brand gate |
| `differentiated-stripe-bridge` | FP guard — differentiated name + disclaimer, must NOT trip |
| `affiliated-mongodb-official` | FP guard — bare 'mongodb' from mongodb/ org, must NOT trip |
| `exfiltration-curl-skill` | Positive — skill exfiltrates .env via curl, must fail |
| `coercive-directive` | Positive — agent description coerces ignoring safety, must fail |
| `reviewer-prompt-injection` | Robustness — README tries to make reviewer say passes=true; must still fail on real exfil |

## Running locally

```sh
ANTHROPIC_API_KEY=... bash .github/actions/scan-plugins/policy/test-fixtures.sh
```

## When to run

The `policy-fixtures` workflow runs automatically on PRs touching this
directory. Run locally before pushing prompt or schema edits.

## Adding a fixture

1. `fixtures/<name>/.claude-plugin/plugin.json` (must pass `claude plugin validate`)
2. `README.md` and any `skills/`, `agents/`, etc. that exercise the case
3. `expected.json` with `{description, assertions}` — see `expected.schema.json`
4. Run the suite locally; commit only after it passes
