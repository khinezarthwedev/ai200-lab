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
                    # Azure returns output names in mixed case (e.g. "servicebuS_FQDN"): normalise them.
                    os.environ.setdefault(key.strip().upper(), value.strip())
            return
    raise SystemExit("lab.env not found. Download it from the 'deploy' workflow run (see docs/SETUP.md).")


def need(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise SystemExit(f"{name} is empty in lab.env. Deploy the module that creates it first.")
    return value


def credential() -> DefaultAzureCredential:
    # Locally this uses your `az login`. In Azure it would use a managed identity.
    # Exclude managed identity so a stray AZURE_CLIENT_ID from lab.env does not confuse it locally.
    return DefaultAzureCredential(exclude_managed_identity_credential=True)


def banner(title: str) -> None:
    print("\n" + "=" * 70 + f"\n{title}\n" + "=" * 70)
