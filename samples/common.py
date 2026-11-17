"""Shared helpers for the samples.

Run the samples from your own PC or Azure Cloud Shell after `az login`. They read resource names
from lab.env, which the deploy workflow publishes as a downloadable artifact (see docs/SETUP.md).
"""

import os
from pathlib import Path

from azure.core.credentials import TokenCredential
from azure.identity import AzureCliCredential, ChainedTokenCredential, DefaultAzureCredential


def load_env(path: str = "lab.env") -> None:
    for candidate in (Path(path), Path(__file__).parent / path, Path(__file__).parent.parent / path):
        if candidate.exists():
            for line in candidate.read_text().splitlines():
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    key = key.strip().upper()  # Azure returns mixed case, e.g. "servicebuS_FQDN"
                    if key == "AZURE_CLIENT_ID":
                        # That is the APPS' managed identity. If it were in the environment, the
                        # credential would try to sign in as it (which only works inside Azure apps).
                        continue
                    os.environ.setdefault(key, value.strip())
            return
    raise SystemExit("lab.env not found. Download it from the 'deploy' workflow run (see docs/SETUP.md).")


def need(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise SystemExit(f"{name} is empty in lab.env. Deploy the module that creates it first.")
    return value


def in_cloud_shell() -> bool:
    return bool(os.getenv("ACC_CLOUD")) or os.getenv("AZUREPS_HOST_ENVIRONMENT", "").startswith("cloud-shell")


def credential() -> TokenCredential:
    """Signs in as YOU.

    Azure Cloud Shell: through the Azure CLI login that Cloud Shell already has. (Cloud Shell's
    built-in identity endpoint only gives tokens for a few services; for Service Bus it fails with
    'AudienceNotSupported', so it is skipped there.)
    Your own PC: DefaultAzureCredential finds your `az login`.
    In the deployed apps the same DefaultAzureCredential picks up the managed identity instead.
    """
    if in_cloud_shell():
        return ChainedTokenCredential(
            AzureCliCredential(process_timeout=60),
            DefaultAzureCredential(exclude_managed_identity_credential=True, process_timeout=60),
        )
    return DefaultAzureCredential(process_timeout=60)


def banner(title: str) -> None:
    print("\n" + "=" * 70 + f"\n{title}\n" + "=" * 70)
