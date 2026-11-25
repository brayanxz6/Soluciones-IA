#!/usr/bin/env bash
# Diagnóstico del despliegue. Código de salida != 0 si hay fallos críticos.
set -uo pipefail
cd "$(dirname "$0")"

OK=0; FALLOS=0; AVISOS=0
ok()    { echo "  [OK]    $*"; OK=$((OK+1)); }
fallo() { echo "  [FALLO] $*"; FALLOS=$((FALLOS+1)); }
aviso() { echo "  [AVISO] $*"; AVISOS=$((AVISOS+1)); }
seccion() { echo; echo "== $* =="; }

getenv_file() { [ -f .env ] && grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }
PUERTO="$(getenv_file API_PORT)"; PUERTO="${PUERTO:-8000}"
API="http://localhost:${PUERTO}"

seccion "Docker"
if docker info >/dev/null 2>&1; then ok "Daemon de Docker activo"; else fallo "Docker no responde"; exit 1; fi
[ -f .env ] && ok "Archivo .env presente" || fallo ".env no existe (ejecuta ./setup.sh)"

seccion "Contenedores"
for c in db-ia api-ia; do
  estado="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo ausente)"
  salud="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "$c" 2>/dev/null || echo -)"
  if [ "$estado" = "running" ] && [ "$salud" = "healthy" ]; then ok "$c: running/healthy"
  else fallo "$c: estado=$estado salud=$salud"; fi
done
red="$(docker network ls --format '{{.Name}}' | grep -c 'red-ia' || true)"
[ "$red" -ge 1 ] && ok "Red red-ia presente" || fallo "Red red-ia no encontrada"

seccion "Seguridad del contenedor API"
uid="$(docker exec api-ia id -u 2>/dev/null || echo ?)"
[ "$uid" = "1001" ] && ok "api-ia se ejecuta como UID 1001 (appuser)" || fallo "UID de api-ia = $uid (esperado 1001)"
pub="$(docker port db-ia 2>/dev/null | wc -l | tr -d ' ')"
[ "$pub" = "0" ] && ok "PostgreSQL no está publicado al host" || aviso "PostgreSQL expone puertos al host"

seccion "API"
if curl -fsS --max-time 5 "$API/health" >/dev/null 2>&1; then ok "GET /health"; else fallo "GET /health no responde en $API"; fi
if curl -fsS --max-time 5 "$API/ready" >/dev/null 2>&1; then ok "GET /ready (BD alcanzable por la API)"; else fallo "GET /ready: la API no alcanza la BD"; fi
resp="$(curl -fsS --max-time 5 -X POST "$API/clasificar" -H 'Content-Type: application/json' \
        -d '{"mensaje":"fix: diagnostico"}' 2>/dev/null || true)"
if echo "$resp" | grep -q '"categoria":"fix"'; then ok "POST /clasificar (motor eco) -> fix"; else fallo "POST /clasificar falló: ${resp:-sin respuesta}"; fi
echo "$resp" | grep -q '"persistido":true' && ok "Persistencia en BD funcionando" || fallo "La clasificación no se persistió"

seccion "Privilegios del rol app_ia"
PW="$(getenv_file APP_DB_PASSWORD)"
DB="$(getenv_file POSTGRES_DB)"; DB="${DB:-commits_db}"
psql_app() { docker exec -e PGPASSWORD="$PW" db-ia psql -h db-ia -U app_ia -d "$DB" -v ON_ERROR_STOP=1 -tA -c "$1" 2>&1; }
psql_app "SELECT count(*) FROM clasificaciones" >/dev/null && ok "SELECT permitido" || fallo "SELECT denegado a app_ia"
for sql in "UPDATE clasificaciones SET categoria='fix' WHERE false" \
           "DELETE FROM clasificaciones WHERE false" \
           "DROP TABLE clasificaciones"; do
  if psql_app "$sql" | grep -qi "permission denied\|must be owner"; then ok "Denegado: ${sql%% *}"
  else fallo "app_ia pudo ejecutar o no se verificó: ${sql%% *}"; fi
done

seccion "Ollama (motor opcional)"
if curl -fsS --max-time 3 http://localhost:11434/api/tags >/tmp/ollama_tags.$$ 2>/dev/null; then
  ok "Ollama responde en localhost:11434"
  for m in gemma3:270m qwen2.5:0.5b qwen2.5-coder:1.5b; do
    grep -q "\"$m\"" /tmp/ollama_tags.$$ && ok "Modelo descargado: $m" || aviso "Modelo no descargado: $m (ollama pull $m)"
  done
  if docker exec api-ia python -c "import urllib.request; urllib.request.urlopen('http://host.docker.internal:11434/api/tags', timeout=3)" >/dev/null 2>&1; then
    ok "api-ia alcanza Ollama vía host.docker.internal"
  else
    aviso "api-ia NO alcanza Ollama. En Linux inicia Ollama con OLLAMA_HOST=0.0.0.0:11434"
  fi
else
  aviso "Ollama no responde en localhost:11434 (solo afecta a motor=ollama)"
fi
rm -f /tmp/ollama_tags.$$

seccion "Recursos"
docker stats --no-stream --format '  {{.Name}}: CPU {{.CPUPerc}} | RAM {{.MemUsage}} ({{.MemPerc}})' db-ia api-ia 2>/dev/null || aviso "No se pudo leer docker stats"
vol="$(docker volume ls --format '{{.Name}}' | grep -c 'datos-pg' || true)"
[ "$vol" -ge 1 ] && ok "Volumen datos-pg presente (persistencia)" || fallo "Volumen datos-pg no encontrado"

echo
echo "Resumen: $OK correctos, $AVISOS avisos, $FALLOS fallos"
[ "$FALLOS" -eq 0 ]
