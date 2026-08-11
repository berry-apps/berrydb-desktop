import os
import requests
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, VectorParams, PointStruct
from dotenv import load_dotenv
import uuid

load_dotenv()

OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL")
EMBEDDING_DIMENSIONS = int(os.getenv("EMBEDDING_DIMENSIONS", 1024))

print(f"Using model: {EMBEDDING_MODEL} with dimensions: {EMBEDDING_DIMENSIONS}")

def get_embedding(text):
    response = requests.post(
        "https://openrouter.ai/api/v1/embeddings",
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "HTTP-Referer": "http://localhost",
            "X-Title": "BerryDB Test"
        },
        json={
            "model": EMBEDDING_MODEL,
            "input": text
        }
    )
    if response.status_code != 200:
        print(f"Error from OpenRouter: {response.text}")
        response.raise_for_status()
    data = response.json()
    return data["data"][0]["embedding"]

texts = [
    "Berry is an amazing note taking app.",
    "Qdrant is a fast vector database.",
    "OpenRouter provides access to multiple AI models.",
    "Vectors are used to find semantic similarity.",
    "Apple is a fruit, but also a technology company."
]

print("Generating embeddings...")
points = []
for i, text in enumerate(texts):
    print(f"Generating embedding for: {text}")
    vector = get_embedding(text)
    if len(vector) > EMBEDDING_DIMENSIONS:
        vector = vector[:EMBEDDING_DIMENSIONS]
    elif len(vector) < EMBEDDING_DIMENSIONS:
        vector = vector + [0.0] * (EMBEDDING_DIMENSIONS - len(vector))
    points.append(PointStruct(id=str(uuid.uuid4()), vector=vector, payload={"text": text, "index": i}))

print("Connecting to Qdrant at localhost:63339...")
client = QdrantClient(url="http://localhost:63339")

collection_name = "sample_collection"
try:
    client.get_collection(collection_name)
    print(f"Collection {collection_name} already exists.")
except Exception:
    print(f"Creating collection {collection_name}...")
    client.create_collection(
        collection_name=collection_name,
        vectors_config=VectorParams(size=EMBEDDING_DIMENSIONS, distance=Distance.COSINE)
    )

print("Inserting points...")
client.upsert(
    collection_name=collection_name,
    points=points
)

print(f"Successfully inserted {len(points)} sample points into Qdrant.")
