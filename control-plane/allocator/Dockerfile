FROM python:3.14-slim
RUN pip install --no-cache-dir -r /dev/stdin <<'EOF'
psycopg[binary]==3.3.2
EOF
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY allocator allocator
USER 10001
ENTRYPOINT ["python", "-m", "allocator"]
