# Compila el hub y el sitio, y deja una imagen con el binario y poco más.
FROM node:22-alpine AS sitio
WORKDIR /sitio
COPY manager/package*.json ./
RUN npm install --silent
COPY manager/ ./
RUN npm run build

FROM dart:stable AS compilador
WORKDIR /app
# El pubspec y su lockfile primero: mientras no cambien, esta capa se reusa y
# la compilación no vuelve a bajar nada.
COPY hub/pubspec.yaml hub/pubspec.lock ./
RUN dart pub get
COPY hub/ ./
RUN dart compile exe bin/chalona_print_hub.dart -o /app/chalona-print-hub

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/chalona-print
COPY --from=compilador /app/chalona-print-hub ./
COPY --from=compilador /app/migraciones ./migraciones
COPY --from=sitio /sitio/dist ./manager
ENV PRINT_MANAGER=/opt/chalona-print/manager
EXPOSE 3070
CMD ["./chalona-print-hub"]
