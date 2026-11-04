# Worker pcm : Python + meshctrl (Node). Image légère pour le DS920+.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates tzdata \
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
COPY worker/meshpipe.js ./worker/meshpipe.js

ENV PYTHONPATH=/app/worker \
    MESHCTRL_CMD="node /opt/meshctrl/node_modules/meshcentral/meshctrl.js" \
    NODE_PATH=/opt/meshctrl/node_modules \
    TZ=Europe/Paris \
    PCM_DB=/data/pcm.sqlite \
    PCM_MAPPING=/config/mapping.json \
    PCM_SOFTWARE=/config/logiciels.json \
    PCM_INSTALLERS=/config/installeurs.json \
    PCM_INSTALLERS_DIR=/installeurs

# Le commit de l'image, posé par le workflow : la page Postes l'affiche.
ARG PCM_VERSION=dev
ENV PCM_VERSION=${PCM_VERSION}

USER node
ENTRYPOINT ["python3", "-m", "pcm"]
CMD ["devices"]
