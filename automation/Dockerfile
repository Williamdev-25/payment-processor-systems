FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY remediate.py .

RUN useradd -u 1000 botuser && chown -R botuser /app
USER botuser

ENTRYPOINT ["python", "remediate.py"]
