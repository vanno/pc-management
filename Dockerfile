# Worker pcm : Python + meshctrl (Node). Image légère pour le DS920+.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/meshctrl
# meshctrl.js est livré dans le paquet npm meshcentral. Version figée,
# à aligner sur celle du serveur MeshCentral du NAS.
ARG MESHCENTRAL_VERSION=1.2.5
RUN npm install --omit=dev --no-audit --no-fund meshcentral@${MESHCENTRAL_VERSION} \
 && npm cache clean --force

WORKDIR /app
COPY agent ./agent
COPY worker/pcm ./worker/pcm

ENV PYTHONPATH=/app/worker \
    MESHCTRL_CMD="node /opt/meshctrl/node_modules/meshcentral/meshctrl.js" \
    PCM_DB=/data/pcm.sqlite \
    PCM_MAPPING=/config/mapping.json

USER node
ENTRYPOINT ["python3", "-m", "pcm"]
CMD ["devices"]
