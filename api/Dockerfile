FROM python:3.11-slim

WORKDIR /app

# docker-py needs the docker CLI's client libs only (no daemon needed here,
# it talks to the mounted socket directly), so plain pip install is enough.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
