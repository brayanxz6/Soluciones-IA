# Clasificador de Mensajes de Commit con IA Local

API REST que clasifica mensajes de commit de Git en categorías de
[Conventional Commits](https://www.conventionalcommits.org/) (`feat`, `fix`,
`docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`)
**sin enviar datos a servicios externos**.

| Motor | Descripción | RAM | Latencia típica |
|-------|-------------|-----|-----------------|
| `eco` (defecto) | Expresiones regulares | ~0 | milisegundos |
| `ollama` | Modelo cuantizado local vía API REST de Ollama | según modelo | ver `docs/informe-tecnico.md` |

Modelos Ollama admitidos: `gemma3:270m`, `qwen2.5:0.5b`, `qwen2.5-coder:1.5b`.

## Inicio rápido

Requisitos: Docker con Compose v2 (y opcionalmente [Ollama](https://ollama.com)).

```bash
./setup.sh                      # genera .env con secretos aleatorios y levanta todo
./setup.sh --ollama gemma3:270m # además descarga el modelo en Ollama local
./diagnostico.sh                # verifica contenedores, API, privilegios y Ollama
```

Documentación interactiva: <http://localhost:8000/docs>

```bash
curl -s -X POST localhost:8000/clasificar \
  -H 'Content-Type: application/json' \
  -d '{"mensaje": "fix(api): corrige error al guardar el perfil"}'

curl -s -X POST localhost:8000/clasificar \
  -H 'Content-Type: application/json' \
  -d '{"mensaje": "make it better", "motor": "ollama", "modelo": "qwen2.5:0.5b"}'
```

## Endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| POST | `/clasificar` | Clasifica un mensaje (`mensaje`, `motor`, `modelo`) |
| GET | `/historial?limite=20` | Últimas clasificaciones persistidas |
| GET | `/categorias` | Categorías y modelos admitidos |
| GET | `/health` | Liveness (healthcheck de Docker) |
| GET | `/ready` | Readiness (incluye conexión a BD) |

Códigos de error: `422` entrada inválida · `502` respuesta inválida del modelo
o modelo no descargado · `503` Ollama o BD no disponibles.

## Seguridad

- Contenedor con `appuser` (UID 1001), `read_only`, `cap_drop: ALL`, `no-new-privileges`.
- BD no publicada al host; solo accesible en la red `red-ia`.
- Rol `app_ia` con **únicamente** `CONNECT`, `USAGE`, `SELECT`, `INSERT`
  (sin `UPDATE`/`DELETE`/`DROP`), verificado en pruebas y en `diagnostico.sh`.
- Secretos en `.env` (ignorado por git), generados aleatoriamente por `setup.sh`.
- El modelo solo puede ser uno de la lista blanca; la salida del LLM se valida
  contra las categorías permitidas (mitiga inyección de prompt).

## Desarrollo local (sin Docker para la API)

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pytest httpx==0.27.2 ruff
# BD de pruebas: ver docs/manual-tecnico.md §7
cp .env.example .env                # ajusta DB_PASSWORD = APP_DB_PASSWORD
uvicorn app.main:app --reload
```

## Pruebas

```bash
ruff check .
pytest -v                                       # las pruebas de BD se omiten si no hay Postgres

# Carga contra motor eco (k6)
k6 run tests/carga/prueba_carga.js
k6 run -e VUS=60 tests/carga/prueba_carga.js

# Caracterización secuencial de latencia/precisión (motor ollama)
python tests/carga/caracterizar_modelo.py --modelo qwen2.5:0.5b -n 30
python tests/carga/caracterizar_modelo.py --todos -n 20 --salida resultados.json
```

Las pruebas de BD en local requieren aplicar `db/init.sql` con `psql >= 15`
y `APP_DB_PASSWORD` exportada (ver `docs/manual-tecnico.md`).

## Estructura

```text
app/main.py            API, motores y persistencia
db/init.sql            esquema + rol app_ia de privilegios mínimos
tests/                 pruebas funcionales y de carga
docs/                  informe técnico y manual técnico
.github/workflows/     CI: ruff, pytest (Postgres efímero), build Docker
```

## Operación

- Reiniciar desde cero (borra datos): `./setup.sh --reset`
- Logs: `docker compose logs -f api-ia`
- `db/init.sql` solo se ejecuta al crear el volumen por primera vez.
