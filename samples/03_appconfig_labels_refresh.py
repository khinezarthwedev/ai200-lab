"""App Configuration: labels per environment + dynamic refresh with a sentinel key.
python 03_appconfig_labels_refresh.py                                         (Q98, Q99)
"""

import time

from azure.appconfiguration import AzureAppConfigurationClient, ConfigurationSetting
from azure.appconfiguration.provider import SettingSelector, WatchKey, load

from common import banner, credential, load_env, need

load_env()
endpoint, cred = need("AZURE_APPCONFIG_ENDPOINT"), credential()

banner("Labels: same key 'AI:ModelVersion', different value per environment")
for env in ("test", "staging", "production"):
    cfg = load(endpoint=endpoint, credential=cred, selects=[SettingSelector(key_filter="AI:*", label_filter=env)])
    print(f"{env:<11} -> AI:ModelVersion = {cfg['AI:ModelVersion']}")

banner("Key Vault reference: App Configuration holds a pointer, the provider resolves it")
cfg = load(endpoint=endpoint, credential=cred, keyvault_credential=cred)
print("Partner:ApiKey resolved from Key Vault:", cfg["Partner:ApiKey"][:8] + "...")

banner("Dynamic refresh: change a value, bump Sentinel, the app sees it WITHOUT restarting")
cfg = load(
    endpoint=endpoint,
    credential=cred,
    selects=[SettingSelector(key_filter="*", label_filter="\0")],
    refresh_on=[WatchKey("Sentinel")],
    refresh_interval=5,  # short for the demo; ~30 s is typical
)
print("Search:TopK before:", cfg["Search:TopK"])

admin = AzureAppConfigurationClient(endpoint, cred)
new_top_k = "10" if cfg["Search:TopK"] == "5" else "5"
admin.set_configuration_setting(ConfigurationSetting(key="Search:TopK", value=new_top_k))
sentinel = admin.get_configuration_setting(key="Sentinel")
admin.set_configuration_setting(ConfigurationSetting(key="Sentinel", value=str(int(sentinel.value) + 1)))  # LAST
print("Changed Search:TopK and bumped Sentinel. Waiting for the refresh interval...")

time.sleep(6)
cfg.refresh()  # cheap ETag check of Sentinel -> changed -> reload everything
print("Search:TopK after refresh():", cfg["Search:TopK"])
