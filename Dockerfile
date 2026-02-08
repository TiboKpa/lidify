# Lidify ARM64 Edition (Source Build for AI)
# This version BUILDS Essentia from source because no PyPI wheels exist for ARM64.
# It will take 30-60 minutes to build.
FROM node:20-slim

# Install system dependencies including build tools for ARM64 compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg lsb-release curl ca-certificates git && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

# Add heavy build dependencies for compiling Essentia & TensorFlow C API
# FIX: Replaced libavresample-dev (deprecated) with libswresample-dev
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
    # Build Tools for Essentia
    build-essential \
    python3-dev \
    python3-pip \
    python3-numpy \
    pkg-config \
    libhdf5-dev \
    libfftw3-dev \
    libyaml-dev \
    libsamplerate0-dev \
    libtag1-dev \
    libchromaprint-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    cmake \
    wget \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app/backend /app/frontend /app/audio-analyzer /app/models \
    /data/postgres /data/redis /run/postgresql /var/log/supervisor \
    && chown -R postgres:postgres /data/postgres /run/postgresql

# ============================================
# TENSORFLOW C API & ESSENTIA BUILD
# ============================================
WORKDIR /tmp

# 1. Install TensorFlow C API (Required for building essentia-tensorflow)
# Using the Official Google URL for 2.15.0 ARM64
RUN wget -q https://storage.googleapis.com/tensorflow/libtensorflow/libtensorflow-cpu-linux-aarch64-2.15.0.tar.gz && \
    tar -C /usr/local -xzf libtensorflow-cpu-linux-aarch64-2.15.0.tar.gz && \
    ldconfig && \
    rm libtensorflow-cpu-linux-aarch64-2.15.0.tar.gz

# 2. Build Essentia from source with TensorFlow support
WORKDIR /tmp/essentia-build
# We use --depth 1 to speed up clone
RUN git clone --depth 1 https://github.com/MTG/essentia.git . && \
    # Configure build with TensorFlow support
    python3 wscript --tensorflow --mode=release --with-examples --with-vamp && \
    # Compile
    python3 waf configure --tensorflow --mode=release --with-examples --with-vamp && \
    python3 waf && \
    python3 waf install && \
    # Clean up build artifacts to save space
    cd / && rm -rf /tmp/essentia-build

# 3. Install Python dependencies (including the TensorFlow python package to match C API)
WORKDIR /app/audio-analyzer
RUN pip3 install --no-cache-dir --break-system-packages --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir --break-system-packages \
    'tensorflow==2.15.1' \
    redis \
    psycopg2-binary \
    'numpy<2.0.0'

# Download Essentia ML models
RUN echo "Downloading Essentia ML models..." && \
    curl -L --progress-bar -o /app/models/msd-musicnn-1.pb "https://essentia.upf.edu/models/autotagging/msd/msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_happy-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_happy/mood_happy-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_sad-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_sad/mood_sad-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_relaxed-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_relaxed/mood_relaxed-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_aggressive-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_aggressive/mood_aggressive-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_party-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_party/mood_party-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_acoustic-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_acoustic/mood_acoustic-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/mood_electronic-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/mood_electronic/mood_electronic-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/danceability-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/danceability/danceability-msd-musicnn-1.pb" && \
    curl -L --progress-bar -o /app/models/voice_instrumental-msd-musicnn-1.pb "https://essentia.upf.edu/models/classification-heads/voice_instrumental/voice_instrumental-msd-musicnn-1.pb"

COPY services/audio-analyzer/analyzer.py /app/audio-analyzer/

# ============================================
# CLAP ANALYZER SETUP (Vibe Similarity)
# ============================================
WORKDIR /app/audio-analyzer-clap

# CLAP dependencies
RUN pip3 install --no-cache-dir --break-system-packages \
    'torch>=2.0.0' \
    'torchaudio>=2.0.0' \
    'torchvision>=0.15.0' \
    'laion-clap>=1.1.4' \
    'librosa>=0.10.0' \
    'transformers>=4.30.0' \
    'pgvector>=0.2.0' \
    'python-dotenv>=1.0.0' \
    'requests>=2.31.0'

COPY services/audio-analyzer-clap/analyzer.py /app/audio-analyzer-clap/
RUN echo "Downloading CLAP model..." && \
    curl -L --progress-bar -o /app/models/music_audioset_epoch_15_esc_90.14.pt \
        "https://huggingface.co/lukewys/laion_clap/resolve/main/music_audioset_epoch_15_esc_90.14.pt"

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

# Supervisor config (Full version with AI)
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
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=10

[program:redis]
command=/usr/bin/redis-server --dir /data/redis --appendonly yes
user=redis
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=20

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

[program:audio-analyzer]
command=/bin/bash -c "/app/wait-for-db.sh 120 && cd /app/audio-analyzer && python3 analyzer.py"
autostart=true
autorestart=unexpected
startretries=3
startsecs=10
environment=DATABASE_URL="postgresql://lidify:lidify@localhost:5432/lidify",REDIS_URL="redis://localhost:6379",MUSIC_PATH="/music",BATCH_SIZE="10",SLEEP_INTERVAL="5",MAX_ANALYZE_SECONDS="90",BRPOP_TIMEOUT="30",MODEL_IDLE_TIMEOUT="300",NUM_WORKERS="2",THREADS_PER_WORKER="1",CUDA_VISIBLE_DEVICES=""
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=50

[program:audio-analyzer-clap]
command=/bin/bash -c "/app/wait-for-db.sh 120 && cd /app/audio-analyzer-clap && python3 analyzer.py"
autostart=true
autorestart=unexpected
startretries=3
startsecs=30
environment=DATABASE_URL="postgresql://lidify:lidify@localhost:5432/lidify",REDIS_URL="redis://localhost:6379",MUSIC_PATH="/music",BACKEND_URL="http://localhost:3006",SLEEP_INTERVAL="5",NUM_WORKERS="1",MODEL_IDLE_TIMEOUT="300",INTERNAL_API_SECRET="lidify-internal-aio"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=60
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
