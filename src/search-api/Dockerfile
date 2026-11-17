# Base image comes from Docker Hub. An ACR Task with a BASE IMAGE UPDATE trigger rebuilds this image
# automatically when python:3.12-slim is patched (Proseware requirement).
FROM python:3.12-slim

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# No secrets in the image: everything comes from App Configuration / Key Vault at runtime.
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
