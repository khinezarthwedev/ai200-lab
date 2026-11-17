"""A tiny, free stand-in for a real embedding model.

A real system would call an embedding model (e.g. Azure OpenAI). To keep this lab free and simple,
we turn text into a 64-number vector using hashing. Similar words give similar vectors, which is
enough to practise vector search in Cosmos DB and pgvector.
"""

import hashlib
import math
import re

DIMENSIONS = 64


def embed(text: str) -> list[float]:
    vector = [0.0] * DIMENSIONS
    for word in re.findall(r"[a-z0-9]+", text.lower()):
        digest = hashlib.sha256(word.encode()).digest()
        index = digest[0] % DIMENSIONS
        sign = 1.0 if digest[1] % 2 == 0 else -1.0
        vector[index] += sign
    norm = math.sqrt(sum(v * v for v in vector)) or 1.0
    return [round(v / norm, 6) for v in vector]
