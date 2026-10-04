# ¿API (plumber2) y app (Shiny) en el mismo repo o en repos separados?

Contexto: la app Shiny es un cliente delgado (solo UI + llamadas httr2/mirai). Todas las
decisiones (validación, viajes, política, sensibilidad) viven en la API plumber2.
El contrato entre ambas está en `API_CONTRACT.md`.

> Supuestos (confirmar): un solo equipo mantiene ambas piezas, el contrato todavía está
> cambiando y no hay otros consumidores de la API. Si alguno es falso, ver "Disparadores".

## Matriz comparativa

✅ favorece · ⚠️ depende / requiere disciplina o tooling · ❌ desfavorece

| # | Criterio | Monorepo | Repos separados |
|---|----------|----------|-----------------|
| 1 | Cambios de contrato (ruta/campo nuevo en API **y** UI) | ✅ Un solo PR, atómico; imposible desincronizar versiones | ❌ Dos PRs coordinados; ventana en la que app y API no coinciden |
| 2 | Refactors y renombres entre capas | ✅ Búsqueda y cambio en un solo lugar | ❌ Hay que perseguir referencias entre repos |
| 3 | Pruebas de integración / de contrato en CI | ✅ El CI levanta API + app juntas | ⚠️ Hay que publicar el contrato o una imagen de la API para probar contra ella |
| 4 | Entorno de desarrollo local | ✅ Un clone, un comando para levantar todo | ⚠️ Dos clones y versiones compatibles; de ahí el `dev/mock_api.R` |
| 5 | Onboarding y visibilidad del sistema completo | ✅ Todo en un lugar | ⚠️ Hay que documentar cómo encajan los repos |
| 6 | Despliegue independiente de API y app | ⚠️ Posible con CI por rutas (`paths:`), pero hay que configurarlo | ✅ Natural: cada repo tiene su pipeline |
| 7 | Cadencias de release distintas | ⚠️ Hay que versionar con tags por carpeta | ✅ Versionado y changelog propios |
| 8 | Propiedad y permisos por equipo | ⚠️ `CODEOWNERS`, pero el acceso al repo es común | ✅ Permisos finos por repo |
| 9 | Aislamiento de dependencias (`renv`) | ⚠️ Dos `renv.lock` en un repo; fácil mezclar | ✅ Cada uno con su lockfile y su imagen |
| 10 | Reutilización de la API por otros clientes | ⚠️ La API queda "dentro" del repo de la app | ✅ La API es un producto con su propio ciclo |
| 11 | Artefactos pesados (modelo, datos) | ❌ Inflan el historial y los clones de quien solo toca la UI | ✅ Solo el repo de la API los carga (Git LFS u otro almacén) |
| 12 | Secretos y superficie de seguridad | ⚠️ Credenciales/datos del modelo visibles para quien toca la UI | ✅ Acceso mínimo: la UI no necesita ver nada del modelo |
| 13 | Complejidad de CI/CD | ⚠️ Un pipeline con filtros por ruta y varios jobs | ⚠️ Pipelines simples por repo, pero la integración entre ambos requiere orquestación |

Recuento bruto: monorepo 5 ✅ · 7 ⚠️ · 1 ❌ — separados 7 ✅ · 4 ⚠️ · 2 ❌.
**No es un criterio de decisión por sí solo**: las filas 1–5 pesan mucho mientras el
contrato cambia y hay un solo equipo; las filas 6–13 pesan cuando el sistema madura.

## Recomendación

**Hoy: monorepo con fronteras estrictas. Separar cuando se cumpla algún disparador.**

Razón principal: con un contrato que aún evoluciona y un solo equipo, el mayor costo es
la desincronización entre API y app (filas 1–4), y el monorepo lo elimina. Las ventajas
de separar (filas 6–13) todavía no se están pagando.

Fronteras que hacen barata la separación futura:

- La app **nunca** importa código de la API ni al revés; solo hablan por HTTP.
- El contrato vive en un solo archivo versionado (hoy `API_CONTRACT.md`; ideal: `openapi.yaml`).
- Cada pieza tiene su propio `DESCRIPTION`/`renv.lock`, `tests/` y `Dockerfile`.
- El CI usa filtros por ruta, de modo que tocar `app/` no redespliega `api/`.

### Disparadores para separar en dos repos

1. El modelo o los datos pesan lo suficiente para afectar clones e historial (fila 11).
2. Un segundo cliente consume la API (otra app, un notebook de otro equipo) (fila 10).
3. Equipos distintos con permisos o cadencias de release distintas (filas 7–8).
4. La API maneja secretos o datos que el equipo de UI no debe ver (fila 12).

Con cualquiera de los cuatro, separar deja de ser una preferencia y pasa a ser necesario.

## Estructuras

### A) Monorepo (recomendado hoy)

```
taxi-day/
├── contract/
│   └── openapi.yaml          # o API_CONTRACT.md mientras se formaliza
├── api/                      # plumber2: R/, tests/, renv.lock, Dockerfile
├── app/                      # el proyecto actual (taxi_app) tal cual
│   ├── app.R
│   ├── DESCRIPTION
│   ├── R/  www/  tests/  dev/
├── docker-compose.yml        # api + app para desarrollo y pruebas de integración
└── .github/workflows/
    ├── api.yml               # on: push, paths: ["api/**", "contract/**"]
    └── app.yml               # on: push, paths: ["app/**", "contract/**"]
```

El `dev/mock_api.R` de la app deja de ser imprescindible: se puede levantar la API real
con `docker compose up`. Conviene conservarlo para correr la UI sin el modelo.

### B) Repos separados

```
taxi-day-api/   # plumber2 + contrato (fuente de verdad) + renv.lock + Dockerfile
taxi-day-app/   # el proyecto actual
```

Reglas para que funcione bien:

- El contrato se publica desde el repo de la API (release/tag) y la app fija la versión que usa.
- La app mantiene `dev/mock_api.R` como *stub del consumidor* y un test que lo valida
  contra el contrato publicado.
- Un cambio incompatible exige subir la versión mayor del contrato y coordinar el despliegue.
