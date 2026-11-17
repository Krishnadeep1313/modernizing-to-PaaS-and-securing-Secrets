#!/usr/bin/env bash
# Lab 03 verification. Run INSIDE vm-web-01.
# Proves the VM's Managed Identity can READ (not write) a Key Vault secret,
# and that the SQL server is reachable on port 1433. Never prints the secret value.
#
# Usage: ./verify-managed-identity.sh [vault-name] [sql-server-name] [secret-name]
#   defaults: kv-lab03-krish  sql-server-krish  SqlAdminPassword

VAULT="${1:-kv-lab03-krish}"
SQL="${2:-sql-server-krish}"
SECRET="${3:-SqlAdminPassword}"

echo "Vault: $VAULT   SQL server: $SQL   Secret: $SECRET"
echo

echo "1) Ask the Instance Metadata Service for a Key Vault token"
TOKEN=$(curl -sS --max-time 10 -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
if [ -n "$TOKEN" ]; then
  echo "PASS  token received (${#TOKEN} characters)"
else
  echo "FAIL  no token. Is the VM running and is the System-assigned identity ON?"
  exit 1
fi
echo

echo "2) Read the secret with that token"
BODY=$(curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "https://$VAULT.vault.azure.net/secrets/$SECRET?api-version=7.4" 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL  could not reach https://$VAULT.vault.azure.net"
  echo "      Check the vault name exactly. Key Vault names cannot be changed after creation."
else
  python3 - "$BODY" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("FAIL  unexpected response from Key Vault"); sys.exit(0)
if "value" in d:
    print("PASS  secret read:", d["id"], "| value length:", len(d["value"]))
else:
    e = d.get("error", {})
    print("FAIL ", e.get("code"), "-", str(e.get("message", ""))[:120])
PY
fi
echo

echo "3) Try to WRITE a secret (should be blocked: the VM only has Key Vault Secrets User)"
CODE=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"should-not-work"}' \
  "https://$VAULT.vault.azure.net/secrets/write-test?api-version=7.4" 2>/dev/null)
if [ "$CODE" = "403" ]; then
  echo "PASS  write blocked (HTTP 403): the VM is read-only"
elif [ "$CODE" = "200" ]; then
  echo "FAIL  write succeeded: the identity has too much access (delete the stray 'write-test' secret)"
else
  echo "INFO  HTTP $CODE"
fi
echo

echo "4) Can the VM reach the SQL server on port 1433?"
if timeout 5 bash -c "exec 3<>/dev/tcp/$SQL.database.windows.net/1433" 2>/dev/null; then
  echo "PASS  $SQL.database.windows.net:1433 is reachable (network path only; this is not a login)"
else
  echo "FAIL  cannot reach $SQL.database.windows.net:1433. Check 'Allow Azure services' and the SQL firewall"
fi
