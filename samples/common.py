"""Shared helpers for the samples.

Run the samples from your own PC or Azure Cloud Shell after `az login`. They read resource names
from lab.env, which the deploy workflow publishes as a downloadable artifact (see docs/SETUP.md).
"""

import os
from pathlib import Path

from azure.identity import DefaultAzureCredential


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


def credential() -> DefaultAzureCredential:
    # Signs in as YOU:
    #  - in Azure Cloud Shell: through Cloud Shell's built-in identity endpoint
    #  - on your PC: through `az login` (Azure CLI)
    # In the deployed apps the same class picks up the user-assigned managed identity instead.
    return DefaultAzureCredential(process_timeout=60)


def banner(title: str) -> None:
    print("\n" + "=" * 70 + f"\n{title}\n" + "=" * 70)
