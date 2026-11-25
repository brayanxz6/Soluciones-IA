# Informe Técnico — Clasificador de Mensajes de Commit con IA Local

## 1. Resumen

Se diseñó un servicio que clasifica mensajes de commit en 11 categorías de
Conventional Commits, ejecutándose íntegramente en hardware local. Ofrece dos
motores intercambiables por petición: uno determinista y de coste casi nulo
(`eco`) y otro basado en modelos de lenguaje cuantizados servidos por Ollama.
El resto del sistema (API, base de datos, CI/CD) se diseñó con foco en bajo
consumo de recursos y seguridad por defecto.

## 2. Objetivos y restricciones

- Privacidad: el texto de los commits no sale de la máquina.
- Bajo consumo: operar en equipos modestos (la pila Docker acota RAM: API 256 MB, BD 192 MB).
- Degradación controlada: el servicio útil mínimo (`eco`) no depende de Ollama ni de la BD.
- Seguridad: mínimo privilegio en BD y contenedores.
- Reproducibilidad: despliegue y pruebas automatizados.

## 3. Arquitectura

```text
Cliente ──HTTP──> api-ia (FastAPI) ──SQL──> db-ia (PostgreSQL 16)    [red-ia]
                      │
                      └──HTTP──> Ollama (host) :11434  (solo motor=ollama)
```

| Decisión | Alternativa descartada | Motivo |
|----------|----------------------|--------|
| Motor `eco` por defecto | LLM por defecto | Sin RAM extra, latencia en ms, determinista |
| Ollama vía REST | Cargar el modelo dentro de la API | Aísla el consumo de RAM del modelo y permite cambiarlo sin reconstruir la imagen |
| Lista blanca de modelos | Campo libre | Evita descargas/ejecuciones arbitrarias y limita la superficie |
| Salida estructurada (`format` con JSON Schema, `temperature=0`) | Texto libre | Mejora la fiabilidad en modelos pequeños; además se valida la categoría en servidor |
| Persistencia *best-effort* | Falla si la BD cae | La clasificación no debe depender del historial |
| Endpoints síncronos (`def`) | `async` con `requests` | `requests` es bloqueante; FastAPI los ejecuta en un pool de hilos sin bloquear el loop |
| Pool de conexiones con enfriamiento de 5 s | Conexión por petición | Evita agotar `max_connections=20` y no penaliza cada petición si la BD cae |

### 3.1 Motor eco

Primero busca un prefijo Conventional Commits (`tipo(scope)!:`, confianza 0.95).
Si no existe, aplica reglas por palabras clave en español e inglés con prioridad
fija (revert › test › ci › docs › build › perf › refactor › style › fix › feat),
confianza 0.6; sin coincidencias devuelve `chore` con confianza 0.3. La
prioridad prefiere categorías «específicas» sobre genéricas (p. ej. «add tests»
→ `test`, no `feat`).

**Limitación:** es una línea base léxica; no entiende semántica ni mensajes
ambiguos («make it better»). Los falsos positivos por palabra clave son posibles.

### 3.2 Motor ollama

Prompt con la lista de categorías, el mensaje delimitado con `<mensaje>…</mensaje>`
y la instrucción de ignorar órdenes dentro del mensaje. Parámetros: `stream=false`,
`temperature=0`, `num_predict=48`, `keep_alive` configurable. La respuesta se
interpreta como JSON; si falla, se busca una categoría válida en el texto; si
tampoco, se devuelve 502 en lugar de adivinar.

## 4. Seguridad

| Capa | Medida |
|------|--------|
| BD | Rol `app_ia` con solo `CONNECT`, `USAGE`, `SELECT`, `INSERT`; `PUBLIC` sin permisos; `statement_timeout=5s`; límite de 10 conexiones; BD sin puertos publicados |
| Contenedor | Usuario no-root UID 1001, sistema de archivos de solo lectura, `cap_drop: ALL`, `no-new-privileges`, límites de memoria, imagen multi-etapa sin compiladores |
| Secretos | `.env` ignorado por git, generado con `openssl rand`; la contraseña de `app_ia` se inyecta en `init.sql` con `\getenv`, no está en el repositorio |
| Entrada | Pydantic: 1–500 caracteres, motor y modelo restringidos; consultas SQL parametrizadas |
| LLM | Lista blanca de modelos, delimitación del input, validación estricta de la salida contra las categorías |

**Riesgos residuales:** la API no tiene autenticación ni limitación de tasa (se
asume uso en red local de confianza; en producción añadir un proxy inverso con
autenticación y *rate limiting*). El rol `app_ia` no puede borrar, por lo que el
historial crece sin límite hasta que un administrador lo purgue. En Linux,
exponer Ollama en `0.0.0.0` exige firewall. Los mensajes de commit se almacenan
en claro y podrían contener datos sensibles.

## 5. Metodología de evaluación

### 5.1 Pruebas funcionales (`tests/test_api.py`)
Clasificación eco parametrizada, validaciones 422, motor ollama simulado
(éxito, texto libre, caído, respuesta inválida, modelo ausente), resiliencia sin
BD, persistencia e historial, y comprobación de que `app_ia` recibe
`InsufficientPrivilege` en `UPDATE`, `DELETE`, `TRUNCATE`, `DROP` y `CREATE`.

### 5.2 Carga del motor eco (k6)
`tests/carga/prueba_carga.js`: rampa 4 etapas (calentamiento, sostenida, estrés,
enfriamiento) con umbrales `http_req_failed < 1 %`, `p95 < 500 ms`, `p99 < 1 s`.
Mide el techo de la pila API + BD, ya que cada petición inserta una fila.

### 5.3 Caracterización del motor ollama
`tests/carga/caracterizar_modelo.py`: peticiones **secuenciales** (la concurrencia
sobre un LLM local solo mide la cola), con calentamiento aparte (la primera
petición incluye la carga del modelo). Reporta mínimo, media, mediana, p95,
máximo, desviación, throughput y precisión sobre 20 mensajes etiquetados a mano.

## 6. Estado de la verificación

Esta sección distingue lo que se verificó de forma automatizada de lo que no se
ejecutó. No se incluyen cifras de rendimiento porque no se realizaron las
mediciones de carga.

### 6.1 Verificado (GitHub Actions, ejecución CI #3, todos los jobs en verde)

| Verificación | Job | Resultado |
|--------------|-----|-----------|
| Linting del código con `ruff` | `lint` | Aprobado |
| Suite `pytest`: clasificación eco, validaciones 422, motor ollama simulado, resiliencia sin BD | `test` | Aprobado |
| Persistencia e historial contra un PostgreSQL 16 real | `test` | Aprobado |
| Privilegios mínimos de `app_ia`: `UPDATE`, `DELETE`, `TRUNCATE`, `DROP` y `CREATE` rechazados con `InsufficientPrivilege` | `test` | Aprobado |
| Build de la imagen Docker multi-etapa y ejecución con UID 1001 (no-root) | `docker` | Aprobado |

### 6.2 No ejecutado

| Elemento | Motivo |
|----------|--------|
| Despliegue completo con `docker compose up` (`setup.sh`, `diagnostico.sh`) | No se ejecutó en un entorno con Docker; el CI solo construye la imagen |
| Prueba de carga k6 del motor `eco` (`tests/carga/prueba_carga.js`) | No se ejecutó |
| Caracterización del motor `ollama` con los tres modelos (`tests/carga/caracterizar_modelo.py`) | No se ejecutó; requiere Ollama instalado y modelos descargados |
| Consumo real de RAM de los contenedores y de los modelos | No se midió |

Los scripts de medición están implementados y documentados en el repositorio;
quedan pendientes de ejecución. Los límites de memoria configurados (API 256 MB,
BD 192 MB) son valores de diseño, no mediciones.

## 7. Análisis

No hay mediciones sobre las cuales sacar conclusiones de rendimiento. Lo que
sigue son expectativas derivadas del diseño, que deben tratarse como hipótesis
por contrastar:

- **Motor `eco`:** al ser expresiones regulares sin red ni inferencia, se espera
  una latencia muy inferior a la de cualquier modelo; el coste dominante
  probablemente será la inserción en la base de datos.
- **Motor `ollama`:** se espera mayor latencia y consumo de RAM que `eco`, con
  una primera petición más lenta por la carga del modelo (mitigable con
  `OLLAMA_KEEP_ALIVE`). Se espera que los modelos más grandes sean más lentos,
  y no está comprobado que sean más precisos.
- **Precisión:** no se evaluó la exactitud de ningún motor. El motor `eco` es
  léxico y tiene límites conocidos con mensajes ambiguos.

Para validar estas hipótesis deben ejecutarse los scripts de la sección 5
(`k6 run tests/carga/prueba_carga.js` y
`python tests/carga/caracterizar_modelo.py --todos -n 30 --salida resultados.json`)
y registrar el hardware utilizado.

## 8. Limitaciones y trabajo futuro

- El conjunto de 20 mensajes es pequeño: la precisión es indicativa, no estadística.
- No hay autenticación, *rate limiting* ni política de retención automatizada.
- Mejoras: modo híbrido (eco con baja confianza → escalar a Ollama), evaluación
  con un corpus real de commits, métricas Prometheus, cola de peticiones para
  Ollama, y un rol administrativo separado para retención de datos.

## 9. Conclusiones

El sistema cumple los requisitos de arquitectura y seguridad especificados, y su
correcto funcionamiento fue verificado de forma automatizada en CI: lint,
pruebas funcionales contra PostgreSQL real, privilegios mínimos del rol de
aplicación y construcción de una imagen con usuario no-root. La arquitectura
dual permite un servicio siempre disponible y de bajo coste (`eco`) y una opción
semánticamente más capaz (`ollama`), con fallos aislados entre componentes.

Queda pendiente la validación en entorno desplegado y la medición de
rendimiento (sección 6.2); hasta entonces, la elección entre motores debe
considerarse una decisión de diseño y no una conclusión respaldada por datos.
