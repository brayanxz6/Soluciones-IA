# Manual Técnico

## 1. Componentes

| Componente | Contenedor | Detalle |
|------------|-----------|---------|
| API | `api-ia` | Python 3.12, FastAPI, Uvicorn, usuario `appuser` (UID 1001), 256 MB máx. |
| Base de datos | `db-ia` | PostgreSQL 16 Alpine, `shared_buffers=32MB`, `max_connections=20`, 192 MB máx. |
| Red | `red-ia` | Bridge dedicada; la BD no publica puertos |
| Volumen | `datos-pg` | Persistencia de `/var/lib/postgresql/data` |
| Ollama | host | Externo a Compose; consumido por HTTP |

## 2. Instalación

1. Instalar Docker Engine (o Docker Desktop) con Compose v2.
2. `./setup.sh` — crea `.env` (permisos 600, secretos con `openssl rand`),
   construye la imagen y espera al estado `healthy`.
3. `./diagnostico.sh` — debe terminar con 0 fallos.

### Ollama (opcional)

```bash
ollama pull gemma3:270m      # o qwen2.5:0.5b / qwen2.5-coder:1.5b
```

- **macOS/Windows (Docker Desktop):** `host.docker.internal` funciona sin cambios.
- **Linux:** Ollama escucha por defecto en `127.0.0.1`, inalcanzable desde un
  contenedor. Inícialo con `OLLAMA_HOST=0.0.0.0:11434 ollama serve` (o en el
  servicio systemd con `Environment="OLLAMA_HOST=0.0.0.0:11434"`) y **restringe
  el puerto 11434** con firewall para que solo sea accesible desde la máquina
  y la red de Docker. Compose ya añade `host.docker.internal:host-gateway`.

## 3. Variables de entorno

| Variable | Defecto | Uso |
|----------|---------|-----|
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `commits_db` / `admin_ia` / (obligatoria) | Superusuario de BD (solo administración) |
| `APP_DB_PASSWORD` | (obligatoria) | Contraseña del rol `app_ia`; la lee `db/init.sql` vía `\getenv` |
| `API_PORT` | `8000` | Puerto publicado en el host |
| `OLLAMA_URL` | `http://localhost:11434/api/generate` | Ejecución local |
| `OLLAMA_URL_DOCKER` | `http://host.docker.internal:11434/api/generate` | Ejecución en Compose |
| `OLLAMA_MODEL` | `qwen2.5:0.5b` | Modelo por defecto (lista blanca) |
| `OLLAMA_TIMEOUT` | `60` | Segundos de espera por inferencia |
| `OLLAMA_KEEP_ALIVE` | `5m` | Tiempo que Ollama mantiene el modelo en RAM |
| `DB_HOST/PORT/NAME/USER/PASSWORD` | `localhost/5432/commits_db/app_ia/` | Solo ejecución local de la API |

## 4. Modelo de datos y privilegios

Tabla `clasificaciones` (propiedad del superusuario): `id` (IDENTITY), `mensaje`,
`categoria`, `motor`, `modelo`, `confianza`, `latencia_ms`, `creado_en`, con
restricciones `CHECK` sobre categoría, motor y longitud.

Rol `app_ia`: `LOGIN`, sin superusuario/creación de BD o roles, límite de 10
conexiones, `statement_timeout=5s`. Privilegios: `CONNECT` (BD), `USAGE`
(esquema `public`), `SELECT` e `INSERT` (tabla). `PUBLIC` pierde todo en la BD y el
esquema. Como `id` es `IDENTITY`, `INSERT` no requiere privilegios sobre la secuencia.

Verificación manual:

```bash
docker exec -e PGPASSWORD="$(grep ^APP_DB_PASSWORD .env | cut -d= -f2)" db-ia \
  psql -h db-ia -U app_ia -d commits_db -c "DELETE FROM clasificaciones"
# ERROR: permission denied for table clasificaciones
```

Consecuencia operativa: **la aplicación no puede borrar datos**. La retención
(purgas, anonimización) debe hacerla un administrador con `POSTGRES_USER`.

## 5. Comportamiento ante fallos

| Situación | Resultado |
|-----------|-----------|
| BD caída | `/clasificar` responde 200 con `persistido=false`; `/ready` y `/historial` → 503; reintento de conexión cada 5 s |
| Ollama apagado | `motor=ollama` → 503; `eco` sigue funcionando |
| Modelo no descargado | 502 con instrucción `ollama pull` |
| Salida del LLM inválida | 502 (no se inventa una categoría) |

## 6. Operación

```bash
docker compose ps
docker compose logs -f api-ia
docker compose restart api-ia
docker compose down            # conserva datos
docker compose down -v         # BORRA datos
```

Copia de seguridad y restauración (con el superusuario):

```bash
docker exec db-ia pg_dump -U admin_ia commits_db > respaldo.sql
docker exec -i db-ia psql -U admin_ia commits_db < respaldo.sql
```

Cambiar la contraseña de `app_ia` en una BD existente (`init.sql` no se repite):

```bash
docker exec -it db-ia psql -U admin_ia -d commits_db -c "ALTER ROLE app_ia PASSWORD 'nueva'"
# actualizar APP_DB_PASSWORD en .env y: docker compose up -d api-ia
```

## 7. Pruebas locales con BD

Las pruebas de BD se omiten solas si no hay PostgreSQL. Para ejecutarlas en local,
levanta un Postgres efímero, aplica `db/init.sql` (requiere `psql >= 15`) y apunta
la API de pruebas a él:

```bash
docker run -d --name pg-test -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=commits_db \
  -p 127.0.0.1:5433:5432 postgres:16-alpine
sleep 5
export APP_DB_PASSWORD=local_test_pw PGPASSWORD=postgres
psql -h 127.0.0.1 -p 5433 -U postgres -d commits_db -v ON_ERROR_STOP=1 -f db/init.sql
export DB_HOST=127.0.0.1 DB_PORT=5433 DB_NAME=commits_db DB_USER=app_ia DB_PASSWORD=$APP_DB_PASSWORD
pytest -v
docker rm -f pg-test
```

## 8. CI/CD (`.github/workflows/ci.yml`)

1. **lint**: `ruff check .`
2. **test**: servicio `postgres:16-alpine`, aplica `db/init.sql`, ejecuta `pytest`
   (incluye pruebas de privilegios del rol `app_ia`).
3. **docker**: build de la imagen (tras lint y test) y comprobación de UID 1001.

## 9. Solución de problemas

| Síntoma | Causa probable | Acción |
|---------|---------------|--------|
| `setup.sh` no llega a healthy | Error de BD o puerto ocupado | `docker compose logs`; cambiar `API_PORT` |
| `api-ia` healthy pero `/ready` 503 | Contraseña de `app_ia` distinta a la del volumen | `docker compose down -v` (borra datos) o `ALTER ROLE` |
| `\getenv` falla en `init.sql` | Variable `APP_DB_PASSWORD` ausente | Revisar `.env` y recrear el volumen |
| `motor=ollama` → 503 en Linux | Ollama escucha solo en 127.0.0.1 | Ver sección 2 |
| `motor=ollama` → 502 «Modelo no descargado» | Falta `ollama pull` | Descargar el modelo |
| Latencias altas en la primera petición | Carga del modelo en RAM | Es esperado; ajustar `OLLAMA_KEEP_ALIVE` |
