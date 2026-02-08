# Lidify ARM64 Edition (No AI)
FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg lsb-release curl ca-certificates && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

RUN apt-get install -y --no-install-recommends \
    postgresql-16 \
    postgresql-contrib-16 \
    postgresql-16-pgvector \
    redis-server \
    supervisor \
    ffmpeg \
    tini \
    openssl \
    bash \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app/backend /app/frontend /data/postgres /data/redis /run/postgresql /var/log/supervisor \
    && chown -R postgres:postgres /data/postgres /run/postgresql

# Create database readiness check script
RUN cat > /app/wait-for-db.sh << 'EOF'
#!/bin/bash
TIMEOUT=${1:-120}
COUNTER=0
echo "[wait-for-db] Waiting for database..."
while [ $COUNTER -lt $TIMEOUT ]; do
    if PGPASSWORD=lidify psql -h localhost -U lidify -d lidify -c "SELECT 1" > /dev/null 2>&1; then
        exit 0
    fi
    sleep 1
    COUNTER=$((COUNTER + 1))
done
exit 1
EOF
RUN chmod +x /app/wait-for-db.sh && sed -i 's/\r$//' /app/wait-for-db.sh

# ============================================
# BACKEND BUILD
# ============================================
WORKDIR /app/backend
COPY backend/package*.json ./
COPY backend/prisma ./prisma/
RUN npm ci && npm cache clean --force
RUN npx prisma generate
COPY backend/src ./src
COPY backend/tsconfig.json ./
RUN npm run build
COPY backend/docker-entrypoint.sh ./
COPY backend/healthcheck.js ./healthcheck-backend.js
RUN mkdir -p /app/backend/logs

# ============================================
# FRONTEND BUILD
# ============================================
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm ci && npm cache clean --force
COPY frontend/ ./
ENV NEXT_PUBLIC_BACKEND_URL=http://127.0.0.1:3006
RUN npm run build

# ============================================
# CONFIGURATION
# ============================================
WORKDIR /app
COPY healthcheck-prod.js /app/healthcheck.js

# Supervisor config (AI services removed)
RUN cat > /etc/supervisor/conf.d/lidify.conf << 'EOF'
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/var/run/supervisord.pid
user=root

[program:postgres]
command=/usr/lib/postgresql/16/bin/postgres -D /data/postgres
user=postgres
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis]
command=/usr/bin/redis-server --dir /data/redis --appendonly yes
user=redis
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:backend]
command=/bin/bash -c "/app/wait-for-db.sh 120 && cd /app/backend && node dist/index.js"
autostart=true
autorestart=unexpected
priority=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:frontend]
command=/bin/bash -c "sleep 10 && cd /app/frontend && npm start"
autostart=true
priority=40
environment=NODE_ENV="production",BACKEND_URL="http://localhost:3006",PORT="3030"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# Startup Script
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e
PG_BIN=$(find /usr/lib/postgresql -name "bin" -type d | head -1)

# Init Directories
mkdir -p /data/postgres /data/redis /run/postgresql
chown -R postgres:postgres /data/postgres /run/postgresql
chown -R redis:redis /data/redis
chmod 700 /data/postgres /data/redis

# Init DB
if [ ! -f /data/postgres/PG_VERSION ]; then
    gosu postgres $PG_BIN/initdb -D /data/postgres
    echo "host all all 0.0.0.0/0 md5" >> /data/postgres/pg_hba.conf
    echo "listen_addresses='*'" >> /data/postgres/postgresql.conf
fi

# Start Postgres Temp
gosu postgres $PG_BIN/pg_ctl -D /data/postgres -w start
gosu postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = 'lidify'" | grep -q 1 || \
    gosu postgres psql -c "CREATE USER lidify WITH PASSWORD 'lidify';"
gosu postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'lidify'" | grep -q 1 || \
    gosu postgres psql -c "CREATE DATABASE lidify OWNER lidify;"
gosu postgres psql -d lidify -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Migrations
cd /app/backend
npx prisma migrate deploy

# Stop Postgres
gosu postgres $PG_BIN/pg_ctl -D /data/postgres -w stop

# Secrets & Start
mkdir -p /data/cache/covers /data/cache/transcodes /data/secrets
if [ ! -f /data/secrets/session_secret ]; then
    openssl rand -hex 32 > /data/secrets/session_secret
fi
if [ ! -f /data/secrets/encryption_key ]; then
    openssl rand -hex 32 > /data/secrets/encryption_key
fi

SESSION_SECRET=$(cat /data/secrets/session_secret)
SETTINGS_ENCRYPTION_KEY=$(cat /data/secrets/encryption_key)

exec env \
    NODE_ENV=production \
    DATABASE_URL="postgresql://lidify:lidify@localhost:5432/lidify" \
    SESSION_SECRET="$SESSION_SECRET" \
    SETTINGS_ENCRYPTION_KEY="$SETTINGS_ENCRYPTION_KEY" \
    /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
EOF

RUN chmod +x /app/start.sh

EXPOSE 3030
VOLUME ["/music", "/data"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
