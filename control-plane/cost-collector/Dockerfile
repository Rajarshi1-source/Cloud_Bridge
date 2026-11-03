FROM python:3.14-slim
RUN pip install --no-cache-dir --root-user-action=ignore --disable-pip-version-check -r /dev/stdin <<'EOF'
psycopg[binary]==3.3.7
pyarrow==26.0.0
boto3==1.43.123
google-cloud-bigquery==3.47.0
httpx==0.28.1
PyYAML==6.0.3
EOF
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY collector collector
USER 10001
ENTRYPOINT ["python", "-m", "collector"]
