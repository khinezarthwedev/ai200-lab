"""Upload config/settings.json so the Function 'get_settings' (blob INPUT binding) can read it (Q82).
python 07_upload_blob_settings.py
"""

import json

from azure.storage.blob import BlobServiceClient

from common import credential, load_env, need

load_env()
blob = BlobServiceClient(need("BLOB_ENDPOINT"), credential()).get_blob_client("config", "settings.json")
blob.upload_blob(json.dumps({"modelVersion": "v2", "maxTokens": 512}), overwrite=True)
print("Uploaded. Call: https://<function-app>.azurewebsites.net/api/settings?code=<function key>")
