"""Azure Managed Redis: cache-aside, TTL, invalidation, Entra ID auth.
python 06_redis_cache.py   (needs deployRedis=true)
"""

import json
import time

import redis
from redis_entraid.cred_provider import create_from_default_azure_credential

from common import banner, load_env, need

load_env()
provider = create_from_default_azure_credential(("https://redis.azure.com/.default",))
r = redis.Redis(host=need("REDIS_HOST"), port=10000, ssl=True, credential_provider=provider, decode_responses=True)

banner("Set a cache entry that expires automatically after 600 s (10 minutes)")
r.set("search:support:router", json.dumps(["Reset a router"]), ex=600)
print("TTL remaining:", r.ttl("search:support:router"), "seconds")

banner("Short TTL demo: 3 seconds")
r.set("demo:short", "bye soon", ex=3)
print("now:", r.get("demo:short"))
time.sleep(4)
print("after 4 s:", r.get("demo:short"), "(expired)")

banner("Invalidation: metadata changed -> delete the affected keys right away")
for key in r.scan_iter("search:support:*"):
    r.delete(key)
    print("deleted", key)
