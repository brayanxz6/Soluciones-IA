"""Caracterización secuencial de latencia/precisión del motor ollama.

Las peticiones se hacen UNA A UNA (sin concurrencia): los modelos locales
saturan la CPU y la concurrencia solo mide la cola, no el modelo.

Uso:
  python tests/carga/caracterizar_modelo.py --modelo qwen2.5:0.5b -n 30
  python tests/carga/caracterizar_modelo.py --todos -n 20 --salida resultados.json
"""

import argparse
import json
import statistics
import sys
import time

import requests

MODELOS = ["gemma3:270m", "qwen2.5:0.5b", "qwen2.5-coder:1.5b"]

# (mensaje, categoría esperada) — conjunto de verdad etiquetado a mano
DATASET = [
    ("agregar autenticación con OAuth al login", "feat"),
    ("corrige error al guardar el perfil de usuario", "fix"),
    ("actualiza el README con instrucciones de instalación", "docs"),
    ("refactoriza el módulo de pagos para separar responsabilidades", "refactor"),
    ("añade pruebas unitarias para el parser", "test"),
    ("reduce la latencia de la consulta de reportes con un índice", "perf"),
    ("actualiza dependencias de seguridad en requirements", "build"),
    ("configura el workflow de GitHub Actions para lint", "ci"),
    ("aplica formato black a todo el proyecto", "style"),
    ("revierte el commit a1b2c3 que rompió el login", "revert"),
    ("add pagination to the users endpoint", "feat"),
    ("fix null pointer when cart is empty", "fix"),
    ("document the public API with examples", "docs"),
    ("rename variables for clarity, no behavior change", "refactor"),
    ("speed up image resizing by caching results", "perf"),
    ("update Dockerfile to use a slim base image", "build"),
    ("add integration tests for checkout", "test"),
    ("remove trailing whitespace and fix indentation", "style"),
    ("cache pip dependencies in the CI pipeline", "ci"),
    ("limpieza de archivos temporales del repositorio", "chore"),
]


def percentil(valores, p):
    ordenados = sorted(valores)
    k = max(0, min(len(ordenados) - 1, round(p / 100 * len(ordenados) + 0.5) - 1))
    return ordenados[k]


def caracterizar(url, modelo, n, calentamiento, timeout):
    def llamar(mensaje):
        t0 = time.perf_counter()
        r = requests.post(
            f"{url}/clasificar",
            json={"mensaje": mensaje, "motor": "ollama", "modelo": modelo},
            timeout=timeout,
        )
        return r, (time.perf_counter() - t0) * 1000

    print(f"\n=== {modelo} ===")
    print(f"Calentamiento ({calentamiento} peticiones, carga del modelo en RAM)...")
    for i in range(calentamiento):
        try:
            r, ms = llamar(DATASET[i % len(DATASET)][0])
        except requests.RequestException as exc:
            print(f"  Fallo en calentamiento: {exc}")
            return None
        if r.status_code != 200:
            print(f"  HTTP {r.status_code}: {r.text[:200]}")
            return None
        print(f"  calentamiento {i + 1}: {ms:.0f} ms")

    latencias, aciertos, errores = [], 0, 0
    for i in range(n):
        mensaje, esperada = DATASET[i % len(DATASET)]
        try:
            r, ms = llamar(mensaje)
        except requests.RequestException:
            errores += 1
            continue
        if r.status_code != 200:
            errores += 1
            continue
        latencias.append(ms)
        if r.json()["categoria"] == esperada:
            aciertos += 1

    if not latencias:
        print("  Sin mediciones válidas.")
        return None

    res = {
        "modelo": modelo,
        "peticiones": n,
        "exitosas": len(latencias),
        "errores": errores,
        "precision_pct": round(100 * aciertos / len(latencias), 1),
        "min_ms": round(min(latencias), 1),
        "media_ms": round(statistics.mean(latencias), 1),
        "mediana_ms": round(statistics.median(latencias), 1),
        "p95_ms": round(percentil(latencias, 95), 1),
        "max_ms": round(max(latencias), 1),
        "desv_ms": round(statistics.pstdev(latencias), 1),
        "throughput_rps": round(len(latencias) / (sum(latencias) / 1000), 2),
    }
    for k, v in res.items():
        print(f"  {k:>15}: {v}")
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8000", help="URL base de la API")
    ap.add_argument("--modelo", choices=MODELOS, default="qwen2.5:0.5b")
    ap.add_argument("--todos", action="store_true", help="Probar los 3 modelos")
    ap.add_argument("-n", type=int, default=30, help="Peticiones medidas")
    ap.add_argument("--calentamiento", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--salida", help="Guardar resultados en JSON")
    args = ap.parse_args()

    try:
        requests.get(f"{args.url}/health", timeout=5).raise_for_status()
    except requests.RequestException as exc:
        sys.exit(f"La API no responde en {args.url}: {exc}")

    modelos = MODELOS if args.todos else [args.modelo]
    resultados = [r for m in modelos
                  if (r := caracterizar(args.url, m, args.n, args.calentamiento,
                                        args.timeout))]
    if resultados:
        print("\nResumen")
        print(f"{'modelo':<22}{'prec%':>7}{'media':>9}{'p95':>9}{'rps':>7}{'err':>5}")
        for r in resultados:
            print(f"{r['modelo']:<22}{r['precision_pct']:>7}{r['media_ms']:>9}"
                  f"{r['p95_ms']:>9}{r['throughput_rps']:>7}{r['errores']:>5}")
    if args.salida:
        with open(args.salida, "w", encoding="utf-8") as f:
            json.dump(resultados, f, indent=2, ensure_ascii=False)
        print(f"\nGuardado en {args.salida}")
    sys.exit(0 if resultados else 1)


if __name__ == "__main__":
    main()
