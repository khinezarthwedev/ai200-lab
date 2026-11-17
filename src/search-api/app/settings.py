"""Configuration from Azure App Configuration (+ Key Vault references), with dynamic refresh.

Exam topics:
- labels: same key, different value per environment (APP_ENV = test / staging / production)  (Q99)
- sentinel key + refresh interval: pick up changes WITHOUT restarting                          (Q98)
- Key Vault references: App Configuration stores a pointer; the secret stays in Key Vault      (Q98)
- managed identity (DefaultAzureCredential): no connection strings or passwords anywhere       (Q86, Q98)
"""

import logging
import os

from azure.appconfiguration.provider import SettingSelector, WatchKey, load
from azure.identity import DefaultAzureCredential

log = logging.getLogger(__name__)

credential = DefaultAzureCredential()  # uses AZURE_CLIENT_ID (user-assigned identity) in Azure, az login locally

_config = None

DEFAULTS = {
    "Search:TopK": "5",
    "Search:CacheTtlSeconds": "600",
    "AI:ModelVersion": "local",
}


def load_settings():
    """Load once at startup. Later calls to refresh() reload only if the Sentinel key changed."""
    global _config
    endpoint = os.getenv("AZURE_APPCONFIG_ENDPOINT")
    if not endpoint:
        log.warning("AZURE_APPCONFIG_ENDPOINT not set: using built-in defaults")
        return
    env = os.getenv("APP_ENV", "test")
    _config = load(
        endpoint=endpoint,
        credential=credential,
        selects=[
            SettingSelector(key_filter="*", label_filter="\0"),  # keys with NO label = shared defaults
            SettingSelector(key_filter="*", label_filter=env),  # this environment's values override them
        ],
        refresh_on=[WatchKey("Sentinel")],  # watch ONE key; bump it last after changing others
        refresh_interval=30,  # minimum seconds between checks (it is a cheap ETag check)
        keyvault_credential=credential,  # resolves Key Vault references with the same identity
    )
    log.info("Loaded App Configuration for label '%s'", env)


def refresh():
    """Call often (e.g. on every request). The provider only contacts App Configuration when
    refresh_interval has passed, so this is cheap."""
    if _config is not None:
        try:
            _config.refresh()
        except Exception:  # never fail a user request because a refresh check failed
            log.exception("App Configuration refresh failed")


def get(key: str) -> str:
    if _config is not None and key in _config:
        return _config[key]
    return DEFAULTS.get(key, "")


def is_loaded() -> bool:
    return _config is not None or not os.getenv("AZURE_APPCONFIG_ENDPOINT")
