#!/usr/bin/env bash
# Despliegue en un paso: genera .env con secretos aleatorios, construye y levanta.
#   ./setup.sh                    -> levanta API + BD (motor eco listo)
#   ./setup.sh --ollama [modelo]  -> además descarga un modelo en Ollama local
#   ./setup.sh --reset            -> DESTRUYE datos (volumen) y vuelve a crear todo
set -euo pipefail
cd "$(dirname "$0")"

MODELO_DEFECTO="qwen2.5:0.5b"
USAR_OLLAMA=0; MODELO="$MODELO_DEFECTO"; RESET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ollama) USAR_OLLAMA=1
              if [ $# -gt 1 ] && [[ "$2" != --* ]]; then MODELO="$2"; shift; fi ;;
    --reset)  RESET=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

case "$MODELO" in
  gemma3:270m|qwen2.5:0.5b|qwen2.5-coder:1.5b) ;;
  *) echo "Modelo no permitido: $MODELO (usa gemma3:270m, qwen2.5:0.5b o qwen2.5-coder:1.5b)" >&2; exit 1 ;;
esac

command -v docker >/dev/null || { echo "Docker no está instalado." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Se requiere Docker Compose v2 (docker compose)." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "El daemon de Docker no responde." >&2; exit 1; }

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
  else python3 -c "import secrets; print(secrets.token_hex(16))"; fi
}

if [ "$RESET" -eq 1 ]; then
  read -r -p "Esto BORRA la base de datos (volumen datos-pg). ¿Continuar? [s/N] " r
  [ "$r" = "s" ] || [ "$r" = "S" ] || { echo "Cancelado."; exit 0; }
  docker compose down -v
fi

if [ ! -f .env ]; then
  echo ">> Creando .env con contraseñas aleatorias"
  p1="$(gen_secret)"; p2="$(gen_secret)"
  sed -e "s/CAMBIAR_POSTGRES_PASSWORD/${p1}/g" \
      -e "s/CAMBIAR_APP_PASSWORD/${p2}/g" \
      -e "s/^OLLAMA_MODEL=.*/OLLAMA_MODEL=${MODELO}/" .env.example > .env.tmp
  mv .env.tmp .env
  chmod 600 .env
else
  echo ">> .env ya existe; se conserva"
fi

if [ "$USAR_OLLAMA" -eq 1 ]; then
  if command -v ollama >/dev/null 2>&1; then
    echo ">> Descargando modelo $MODELO"
    ollama pull "$MODELO"
    sed -i.bak "s/^OLLAMA_MODEL=.*/OLLAMA_MODEL=${MODELO}/" .env && rm -f .env.bak
  else
    echo "AVISO: 'ollama' no está instalado (https://ollama.com). El motor ollama no funcionará." >&2
  fi
  echo "AVISO: en Linux, Ollama debe escuchar en 0.0.0.0 para ser alcanzable desde Docker:"
  echo "       OLLAMA_HOST=0.0.0.0:11434 ollama serve   (restringe el puerto con firewall)"
fi

echo ">> Construyendo y levantando servicios"
docker compose up -d --build

echo ">> Esperando a que api-ia esté healthy (máx. 90 s)"
for _ in $(seq 1 45); do
  estado="$(docker inspect -f '{{.State.Health.Status}}' api-ia 2>/dev/null || echo starting)"
  [ "$estado" = "healthy" ] && break
  sleep 2
done
if [ "$estado" != "healthy" ]; then
  echo "La API no quedó healthy. Revisa: docker compose logs" >&2
  exit 1
fi

puerto="$(grep -E '^API_PORT=' .env | cut -d= -f2)"; puerto="${puerto:-8000}"
echo
echo "Listo. API:  http://localhost:${puerto}   Docs: http://localhost:${puerto}/docs"
echo "Prueba:  curl -s -X POST localhost:${puerto}/clasificar -H 'Content-Type: application/json' \\"
echo "           -d '{\"mensaje\":\"fix: corrige error de login\"}'"
echo "Diagnóstico: ./diagnostico.sh"
