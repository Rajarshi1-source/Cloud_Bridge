FROM python:3.14-slim
RUN pip install --no-cache-dir --root-user-action=ignore --disable-pip-version-check -r /dev/stdin <<'EOF'
fastapi==0.162.0
uvicorn==0.54.0
psycopg[binary]==3.3.7
httpx==0.28.1
PyYAML==6.0.3
EOF
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY cpapi cpapi
USER 10001
EXPOSE 8010
CMD ["uvicorn", "cpapi.main:app", "--host", "0.0.0.0", "--port", "8010"]
