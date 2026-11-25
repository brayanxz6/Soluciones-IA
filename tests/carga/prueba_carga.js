// Prueba de carga k6 contra el motor "eco".
//
// Uso:
//   k6 run tests/carga/prueba_carga.js
//   k6 run -e BASE_URL=http://localhost:8000 -e VUS=50 tests/carga/prueba_carga.js
//   docker run --rm -i --network host grafana/k6 run - < tests/carga/prueba_carga.js
//
// Nota: cada petición inserta una fila en la BD (rol app_ia no puede borrarlas).
// Para limpiar tras una prueba masiva: docker compose down -v && ./setup.sh

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
const VUS = parseInt(__ENV.VUS || '30', 10);

const errores = new Rate('errores_clasificacion');
const latenciaApi = new Trend('latencia_api_ms', true);

export const options = {
  stages: [
    { duration: '15s', target: Math.ceil(VUS / 3) }, // calentamiento
    { duration: '30s', target: VUS },                // carga sostenida
    { duration: '30s', target: VUS * 2 },            // estrés
    { duration: '15s', target: 0 },                  // enfriamiento
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    errores_clasificacion: ['rate<0.01'],
  },
};

const MENSAJES = [
  ['feat: agregar autenticación con OAuth', 'feat'],
  ['fix(api): corrige error al guardar el perfil', 'fix'],
  ['docs: actualiza el README', 'docs'],
  ['refactor the payment module', 'refactor'],
  ['add unit tests for the parser', 'test'],
  ['optimiza la consulta de reportes', 'perf'],
  ['bump dependencias de seguridad', 'build'],
  ['configura GitHub Actions', 'ci'],
  ['formatea el código con black', 'style'],
  ['revert: vuelve al commit anterior', 'revert'],
  ['misc things', 'chore'],
];

export function setup() {
  const r = http.get(`${BASE_URL}/health`);
  if (r.status !== 200) {
    throw new Error(`La API no responde en ${BASE_URL}/health (status ${r.status})`);
  }
}

export default function () {
  const [mensaje, esperada] = MENSAJES[Math.floor(Math.random() * MENSAJES.length)];
  const res = http.post(
    `${BASE_URL}/clasificar`,
    JSON.stringify({ mensaje, motor: 'eco' }),
    { headers: { 'Content-Type': 'application/json' } },
  );

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'categoría correcta': (r) => r.status === 200 && r.json('categoria') === esperada,
    'motor eco': (r) => r.status === 200 && r.json('motor') === 'eco',
  });
  errores.add(!ok);
  latenciaApi.add(res.timings.duration);
  sleep(Math.random() * 0.5);
}
