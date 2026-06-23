#!/bin/sh
# TDD unit test for the JWT-minting half of get-token.sh.
#
# get-token.sh signs a GitHub App JWT and exchanges it for an installation
# token. The token exchange needs the real App key + network, so it can't be
# unit-tested here — but the JWT construction (base64url, RS256 signing, the
# claim set) is the part most likely to be subtly wrong, and it IS testable
# offline against a throwaway RSA key.
#
# Contract under test (get-token.sh, JWT_ONLY=1 mode):
#   - emits a well-formed three-segment JWT
#   - header  = {"alg":"RS256","typ":"JWT"}
#   - payload = iss == GITSYNC_APP_CLIENT_ID, iat backdated, 0 < exp-iat <= 600
#   - signature verifies against the App public key (RS256 over header.payload)
#
# Runs offline: generates its own RSA keypair, no GitHub, no secrets.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT_YAML="${REPO_ROOT}/base/git-sync-script.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Extract the shipped get-token.sh out of the ConfigMap (single source of
#    truth — we test exactly what deploys, not a copy).
python3 - "$SCRIPT_YAML" "$WORK/get-token.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
script = doc["data"].get("get-token.sh")
assert script, "get-token.sh missing from ConfigMap data"
open(sys.argv[2], "w").write(script)
PY

# 2. Throwaway keypair standing in for the App private key.
openssl genrsa -out "$WORK/private-key" 2048 >/dev/null 2>&1
openssl rsa -in "$WORK/private-key" -pubout -out "$WORK/public-key" >/dev/null 2>&1

# 3. Run the real script in JWT_ONLY mode (no network, no token exchange).
JWT="$(JWT_ONLY=1 \
  GITSYNC_APP_CLIENT_ID="Iv1.testclientid" \
  GITSYNC_APP_INSTALLATION_ID="99999999" \
  APP_PRIVATE_KEY_FILE="$WORK/private-key" \
  sh "$WORK/get-token.sh")" || fail "get-token.sh exited non-zero in JWT_ONLY mode"

[ -n "$JWT" ] || fail "empty JWT"
printf '%s' "$JWT" > "$WORK/jwt"

# 4. Verify structure, claims, and signature.
python3 - "$WORK/jwt" "$WORK/public-key" "$WORK" <<'PY'
import sys, base64, json, subprocess, time

jwt = open(sys.argv[1]).read().strip()
pub = sys.argv[2]
work = sys.argv[3]

parts = jwt.split(".")
assert len(parts) == 3, f"expected 3 JWT segments, got {len(parts)}"

def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

# Reject base64url padding/altchars leaking through (a common b64 bug).
for seg in parts:
    assert "=" not in seg and "+" not in seg and "/" not in seg, \
        f"segment not base64url-clean: {seg!r}"

header = json.loads(b64url_decode(parts[0]))
assert header == {"alg": "RS256", "typ": "JWT"}, f"bad header: {header}"

payload = json.loads(b64url_decode(parts[1]))
assert payload["iss"] == "Iv1.testclientid", f"bad iss: {payload.get('iss')}"
now = int(time.time())
assert payload["iat"] <= now, f"iat in the future: {payload['iat']} > {now}"
assert payload["exp"] > now, f"exp already past: {payload['exp']} <= {now}"
ttl = payload["exp"] - payload["iat"]
assert 0 < ttl <= 600, f"exp-iat={ttl}s outside GitHub's 10-min ceiling"

# Signature: RS256 over the signing input (header.payload).
signing_input = (parts[0] + "." + parts[1]).encode()
open(work + "/signing_input", "wb").write(signing_input)
open(work + "/sig", "wb").write(b64url_decode(parts[2]))
r = subprocess.run(
    ["openssl", "dgst", "-sha256", "-verify", pub,
     "-signature", work + "/sig", work + "/signing_input"],
    capture_output=True, text=True)
assert r.returncode == 0, f"signature did NOT verify: {r.stdout}{r.stderr}"

print("ok: header, claims, and RS256 signature all valid")
PY

echo "PASS: get-token.sh produces a valid, correctly-signed GitHub App JWT"
