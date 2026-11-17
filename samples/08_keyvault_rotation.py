"""Key Vault: secret versions and rotation without redeploying.
python 08_keyvault_rotation.py

A Key Vault reference WITHOUT a version (e.g. @Microsoft.KeyVault(VaultName=..;SecretName=..))
always resolves to the LATEST version, so rotating the secret needs no redeploy (Q97).
App Service re-reads references periodically (or on restart).
"""

import secrets

from azure.keyvault.secrets import SecretClient

from common import banner, credential, load_env, need

load_env()
kv = SecretClient(need("KEY_VAULT_URI"), credential())

banner("Create a new VERSION of partner-api-key (rotation)")
new = kv.set_secret("partner-api-key", "demo-" + secrets.token_hex(8))
print("new version:", new.properties.version)

banner("All versions (newest first)")
versions = sorted(kv.list_properties_of_secret_versions("partner-api-key"), key=lambda p: p.created_on, reverse=True)
for p in versions:
    print(p.version, p.created_on, "enabled" if p.enabled else "disabled")
