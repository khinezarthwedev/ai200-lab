"""PostgreSQL + pgvector: bulk load first, build the index AFTER, filter by metadata.
python 05_pgvector.py   (needs deployPostgres=true; your IP must be allowed, see docs/SETUP.md)

Exam ideas (Fabrikam case): CREATE EXTENSION vector; secondary indexes only after bulk loading;
HNSW index for fast approximate search; WHERE on metadata so only matching rows are compared.
"""

import psycopg
from azure.keyvault.secrets import SecretClient
from pgvector.psycopg import register_vector

from common import banner, credential, load_env, need
from embeddings import embed

load_env()
# The connection string lives only in Key Vault.
conn_str = SecretClient(need("KEY_VAULT_URI"), credential()).get_secret("postgres-connection-string").value

with psycopg.connect(conn_str, autocommit=True) as conn:
    conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
    register_vector(conn)

    banner("1) Bulk load WITHOUT indexes (fastest ingestion)")
    conn.execute("DROP TABLE IF EXISTS products")
    conn.execute("CREATE TABLE products (id serial PRIMARY KEY, name text, category text, in_stock bool, embedding vector(64))")
    rows = [
        ("trail running shoes", "shoes", True), ("leather office shoes", "shoes", True),
        ("waterproof hiking boots", "shoes", False), ("cotton t-shirt", "clothing", True),
        ("running shorts", "clothing", True), ("espresso machine", "kitchen", True),
    ]
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO products (name, category, in_stock, embedding) VALUES (%s, %s, %s, %s)",
            [(n, c, s, embed(n)) for n, c, s in rows],
        )
    print(f"loaded {len(rows)} rows")

    banner("2) THEN build the indexes")
    conn.execute("CREATE INDEX ON products USING hnsw (embedding vector_cosine_ops)")
    conn.execute("CREATE INDEX ON products (category, in_stock)")
    print("HNSW vector index + metadata index created")

    banner("3) Vector search ONLY among products that match the metadata constraints")
    for row in conn.execute(
        "SELECT name, embedding <=> %s AS distance FROM products "
        "WHERE category = %s AND in_stock ORDER BY embedding <=> %s LIMIT 3",
        (embed("shoes for running"), "shoes", embed("shoes for running")),
    ):
        print(row)
