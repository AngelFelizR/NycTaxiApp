# AGENTS.md

Este repo es el **monorepo** del "NYC Taxi Decision Simulator". El
`04 - Documento Maestro de Decisiones del Proyecto.md` es la **fuente de verdad**
y **no debe modificarse nunca**. Estructura destino (§1.3): `contract/`, `api/`,
`app/`, `share/`, `infra/`, `tools/`, `integration/`, `nix/`, `docs/`,
`.github/workflows/`.
**Fase 0 hecha:** todas las carpetas existen (con `.gitkeep`), los dos
contratos OpenAPI 3.1 están escritos y validados con Spectral (0 errores), y en
la raíz hay `README.md`, `CHANGELOG.md`, `LICENSE` (MIT), `.env.example` y
`AGENTS.md`. **Fases 1 y 2 hechas:** la API (`api/`) tiene `GET /health`,
`POST /predict`, `POST /recommend-start`, `POST /validate-trip-start` y
`POST /sensitivity` (+ caché Redis), con tests y smoke verdes. El `.env` real
ya existe (raíz, gitignored) con `MODELS_DIR` y `DATA_DIR` apuntando a
`~/nyctaxi/{models,data}`. **Fase 3 hecha:** persistencia (`api/migrations/`,
tablas `participants`/`experiments`/`decisions`/`waitlist`), simulación del
día, endpoints `/experiments/*`, `/share-data`, `/waitlist`, `/share-email`
y `/metrics`, rate limit por IP, y `ReferenceDistribution.qs2` ya instalado
en `MODELS_DIR` (suite API 477 assertions + `api/dev/e2e_experiments.sh`
en verde; ver la sección de experimentos). **Fase 4 hecha:** la UI (`app/`)
habla con los endpoints reales del contrato: `mod_setup` con Leaflet
bidireccional, validación con hints, email/marketing, semilla avanzada y el
modal único de `resume_code`; `mod_header`, `mod_confirm_modal` y un
`mod_results` mínimo; estado de sesión en `state.R` (reenvío de `X-Client-IP`);
arranque perezoso de los daemons mirai (< 2 s a "Listening"); mock API en
`app/dev/mock_api.R` y 92 assertions (unit + flujo `shinytest2` en Chromium).
**Split de dependencias Nix hecho:** `nix/pkgs-app.nix` + `nix/r-app.nix` para
la UI, `nix/test-tools.nix` solo con el navegador de los tests, `system.nix`
de vuelta a lo genérico (sin `chromium`) y `r-dev.nix` sin `devtools`/
`roxygen2` (ver la sección de Nix).
**Pendiente:** fase 5 (`mod_trip_card`, `mod_sensitivity`, atajos, barra de
*pending time*) y fase 6 (`mod_results` completo, `share/`) dentro de `app/`;
luego `infra/`, `integration/`, `docs/operations/runbook.md` (§8.8),
`docs/investigation-phases/` (fase 9) y las imágenes/CI (§14, fases 7-9).

## Reglas del monorepo (§1.2, no negociables)
- Un solo `.env` en la raíz · un solo `docker-compose.yml` en la raíz (más
  `docker-compose.prod.yml`) · un solo `default.nix` raíz agregador. Sin submódulos.
- **Compose/default.nix por subcarpeta (acordado):** cada servicio puede tener su
  propio `docker-compose.yml` y sus `default.dev.nix` / `default.prod.nix`
  (4 ficheros: `api/` y `app/`, dev y prod) **solo para probarlo de forma
  individual**. Los de la raíz siguen siendo los canónicos de despliegue; nada de
  producción depende de los de las subcarpetas.
- **Nix (§1.2.3 + decisión):** los módulos viven en `nix/` de la raíz y
  `default.nix` raíz los importa a todos; los `default.*.nix` de cada servicio
  importan solo los suyos. **Pins separados (hecho):**
  `nix/pkgs-api.nix` (nixpkgs **2025-12-02**, R 4.5.2, la que entrenó los
  modelos) para la API y `nix/pkgs-app.nix` (**2026-09-28**) para la UI. Hoy
  apuntan al mismo tarball, así que **nada se reconstruye** (`fetchTarball`
  deriva la store path del URL: ambas dan el mismo `R-4.6.1`), pero ya son el
  punto de cruce para moverlos por separado.
  **Parametrización:** `system.nix`, `r-shiny.nix`, `r-geo.nix`,
  `r-plotting.nix` y `r-dev.nix` son funciones `{ pkgs ? import ./pkgs.nix }:` —
  `nix-build` auto-invoca los defaults, así que **las capas del Dockerfile no
  cambiaron**; el shell raíz pasa `pkgs.nix` y `app/default.dev.nix` pasa
  `pkgs-app.nix`.
  **Agregados:** `nix/r-app.nix` = la UI entera en una expresión
  (`nix-build nix/r-app.nix`, lo que consumirá la imagen de la fase 7) ·
  `nix/test-tools.nix` = **solo** el navegador de `shinytest2`.
  **Sin dependencias huérfanas:** `system.nix` es genérico (R, locales, fuentes)
  y de ahí salió `chromium` (**1,3 GB**: 3701 → 2428 MB de cierre), de modo que
  ninguna imagen que reutilice esa capa herede un navegador que nunca ejecuta;
  `r-dev.nix` perdió `devtools`/`roxygen2` (75 MB: la app no es un paquete, no
  tiene `NAMESPACE` ni `man/`). El shell raíz excluye `r-api.nix`,
  `r-app.nix` y `test-tools.nix`; los `default.prod.nix` de ambos servicios
  siguen **sin crear** (fase 7).
- Cambiar un pin invalida solo las capas Docker de ese servicio; cambiar
  `nix/pkgs*.nix` afecta a las capas que lo usen — hacerlo conscientemente.
- Un solo semver y `CHANGELOG.md`; CI con `paths:` por servicio (§8.6).
- **Red y seguridad (§1, §2.4, §5.4, §5.7):** la API solo existe en la red privada
  de Docker; ningún `ports:` para la API. La clave del `.env` es
  `API_INTERNAL_KEY` y **todo** endpoint exige `X-Internal-Key` (403 sin ella);
  `X-Client-IP` solo se acepta junto con la clave válida. CORS limitado (dominio
  propio en prod, `localhost` en dev, bloquear `Origin: null`). Los clientes
  autorizados son `app/` y `share/`.

## Contratos OpenAPI (`contract/`)
- `contract/openapi.yaml` → API privada (OpenAPI 3.1, 18 endpoints §5.2,
  securitySchemes `InternalKey` + `ResumeCode`, `X-Client-IP`, ejemplos JSON).
- `contract/share.openapi.yaml` → servicio público `share` (3 rutas:
  `GET /share/{token}`, `GET /share/{token}.png`, `POST /waitlist`,
  `security: []`). El enum `outcome` se define en el contrato privado.
- `contract/.spectral.yaml` → `extends: spectral:oas` con `oas3-schema: warn`
  (Spectral valida contra OpenAPI 3.0 y falsa con construcciones 3.1).
- **Validar (host, sin Node; criterio: 0 errores):**
  `docker run --rm -v "$PWD:/repo" -w /repo stoplight/spectral lint contract/openapi.yaml contract/share.openapi.yaml --ruleset contract/.spectral.yaml`
  La imagen es `stoplight/spectral` (**no** `stoplightio/spectral`, no existe).
- Convenciones aprendidas al escribirlos: `example` solo a nivel media-type
  (nunca dentro de un schema), sin `nullable` (usar `type: [string, "null"]` o
  `oneOf` + `type: "null"`), comillas YAML si un scalar plano contiene `: `,
  `operationId` únicos y parámetros de path declarados a nivel path-item.
- Toda la superficie pública se documenta aquí; `app/` y `share/` son los únicos
  clientes de la API y ningún endpoint es accesible desde Internet.

## Tests: tres paquetes de R separados
- `app/` → tests de **UI** (unitarios de módulos + `shinytest2`).
- `api/` → tests de la **API** (`testthat` con el **Postgres fijo del compose**
  raíz, no testcontainers — `docs/decisions/0001-*`), Redis real para el
  caché de `/sensitivity` (se salta si no responde).
- `integration/` en la raíz → paquete R propio de tests de **integración** API↔UI
  (extensión al árbol §1.3; el doc solo contempla `test-contract`, `test-api`,
  `test-shiny`, `test-share` en el CI — añadir `test-integration` al crear el CI).
  Hoy está **vacío** (solo `.gitkeep`): aún no tiene `DESCRIPTION` ni `tests/`.
- `app/` y `api/` sí tienen su `DESCRIPTION` y su `tests/` (ver
  `docs/REPO_DECISION.md`); `share/`, al nacer en la fase 6, repetirá ese patrón.

## La UI vive en `app/`
`app/` contiene la app Shiny completa: `app.R`, `R/`, `www/`, `tests/`, `dev/`
(mock de la API), `DESCRIPTION`. En la raíz solo viven lo compartido:
`default.nix`, `nix/`, `Dockerfile`, `docker-compose.yml`, `setup.sh`, `.envrc`,
`.Rprofile`, `README.md`, `CHANGELOG.md`, `LICENSE`, `.env.example`, docs y
`contract/`.
- `app/tests/testthat/helper-load.R` usa `file.path("..", "..")` → resuelve contra
  `app/`; ejecutar los tests con cwd = `app/`.
- `NAMESPACE`, `man/` y `.Rbuildignore` (restos de la plantilla golem) fueron
  eliminados: no reintroducirlos. `DESCRIPTION` documenta dependencias; no es un
  paquete instalable.
- El `.Rprofile` (guardas de Nix que bloquean `install.packages()`) está en la
  raíz y R solo lo carga si el cwd es la raíz.

## Comandos (cwd = `app/` salvo indicación)
- Tests UI: `nix-shell default.dev.nix --run "Rscript tests/testthat.R"` →
  **92 PASS** (unit + flujo). NO `test_check()`/`devtools::test()`: no es un
  paquete instalado; `helper-load.R` hace `source()` a mano de todo `R/*.R` y
  `R/modules/*.R` (el orden importa). En el shell **raíz** salen
  **82 PASS + 1 SKIP**: ese shell no lleva `test-tools.nix`, así que el test
  de flujo se salta con un mensaje que apunta al shell correcto.
- Un archivo: `testthat::test_file("tests/testthat/test-utils.R")`.
- Tests del **cliente** API sin servidor: `httr2::with_mocked_responses()`
  (`app/tests/testthat/test-api_client.R`) — no confundir con los de la API.
- Test de flujo (`test-shinytest2.R`, fase 4): levanta `dev/mock_api.R` en un
  puerto aleatorio, arranca la app real en Chromium headless y recorre
  Setup → modal → Trips → aceptar viaje, más el reenvío de `X-Client-IP`.
  Requiere `chromium` (`nix/test-tools.nix`, presente en
  `app/default.dev.nix` **no** en el shell raíz) y `NOT_CRAN=true`
  (`AppDriver` se niega a correr si testthat cree que estamos en CRAN; el
  shell y el propio test lo fijan).
- Tests de la API (contenedor, cwd = `api/`): `nix-shell default.dev.nix` y
  `Rscript tests/testthat.R` (477 assertions; Postgres y Redis reales del
  compose raíz — levantar `docker compose up -d` antes). El único skip es
  `test-outcome.R` cuando `MODELS_DIR/ReferenceDistribution.qs2` está
  instalado.
- Smoke de la API (contenedor): `bash api/dev/smoke.sh` (28 casos con timings;
  sensibilidad cold/hit/mobile incluidos).
- E2E de experimentos (contenedor): `bash api/dev/e2e_experiments.sh <ip>`
  (13 pasos con asserts: crear async → setup → in_progress → jugar → finish
  con percentil → abandon 409 → waitlist → metrics). La IP cuenta para el
  límite de 3 experimentos/día, así que **pasar una IP fresca** en cada run.
- **OMP y `fork()` (crítico):** los shells nix (`default.nix` raíz y
  `api/default.dev.nix`) exportan `OMP_NUM_THREADS=1` (más
  `OPENBLAS_NUM_THREADS` y `VECLIB_MAXIMUM_THREADS`). `POST /experiments`
  calcula las trayectorias en un hijo `fork()`eado y libgomp lee esa variable
  **al arrancar R**: sin ella el hijo hereda el pool de OpenMP y se bloquea
  en `futex_wait` con 0 CPU, dejando el día en `setup` para siempre.
  `Sys.setenv()` dentro de R llega tarde (libgomp ya está cargado); si R
  arranca sin la variable, `api/plumber.R` imprime un WARNING y
  `test-experiments-async.R` se salta.
- Reiniciar la API (contenedor): matar con
  `pkill -f "file=api/plumb[e]r"` (el corchete evita que el pkill mate al
  propio shell que lo invoca; el proceso real es
  `R --file=api/plumber.R`, no `Rscript ...`) y relanzar con
  `(nohup nix-shell api/default.dev.nix --run "Rscript api/plumber.R" > /root/api.log 2>&1 &)`
  desde la raíz del repo. El log (`/root/api.log`) incluye los timings de
  `/sensitivity`.
- Datos y Redis: el compose monta `${DATA_DIR}:/data:ro` (parquet de la semana
  + `ZonesShapes.qs2`, `DATA_DIR` en `.env`) y levanta `redis:7`
  (`nyctaxi-redis`); la API lee `DATA_DIR` y `REDIS_HOST`.
- Stub local de la API: `Rscript dev/run_mock_api.R` (plumber2, **puerto
  8010**, API programática `api_get`/`api_post`/`api_run`). **Ya se ejecuta:**
  `test-shinytest2.R` lo levanta en un puerto aleatorio; a mano sirve para
  probar la UI sin modelos ni base de datos. El endpoint real sigue siendo
  `api/plumber.R`.
- Contenedor de desarrollo (cwd = raíz): `./setup.sh` (`-np` para no hacer pull).
  Hoy la imagen solo levanta sshd (host :2222, repo en `/root/NycTaxiApp`): es el
  entorno de desarrollo, **no** las imágenes de despliegue del §1.1.

## Experimentos (fase 3): create asíncrono
- **Divergencia con §4.6** (anotada en `CHANGELOG.md`): `POST /experiments`
  responde **201 en ~0,2 s** con `status: setup`, `model_progress: 0` y
  `next_trip: null`, y las trayectorias policy/baseline se calculan en un hijo
  `fork()`eado mientras el cliente sondea `GET /experiments/{id}/state`
  (`model_progress` 0-99) hasta `in_progress`. El doc describe un create
  síncrono: **no corregir el documento**; manda el código + la nota.
- Guardas: decisions/finish en `setup` → 409 "The day has not started yet.";
  más de **120 s** en `setup` (`SETUP_TIMEOUT_S`) → la fila se abandona y
  `/state` responde 503. `model_progress` solo aparece en el cuerpo mientras
  el estado es `setup`.
- `MODELS_DIR/ReferenceDistribution.qs2` es **requisito de `/finish`**: 200
  con `user_percentile` si existe, 503 si no. Se genera offline con
  `tools/build_reference_distribution.R` (1.000 semillas por compañía,
  ~75 min).
- Las tablas viven en Postgres (nada de experimentos cacheados en
  `model_state`); solo se guardan ahí `traj_jobs` (hijos por recoger) y la
  distribución de referencia. Los tests fijan `API_EXPERIMENTS_SYNC="1"`
  (`helper-load.R`) para que el create corra inline y no haya carreras de
  sondeo.

## Validación del código R (flujo obligatorio)
En el host NO hay R: el único entorno válido es el contenedor de desarrollo.
Para reevaluar o validar cualquier código R, siempre este flujo:
1. **Construir:** `docker compose build` (o `./setup.sh`, que hace pull + up;
   `-np` reutiliza la imagen local sin pull).
2. **Levantar:** `docker compose up -d` → contenedor `nyc-taxi-app` (sshd en :2222).
3. **Entrar:** `ssh NycTaxi` (alias en `~/.ssh/config` → 127.0.0.1:2222, root;
   `setup.sh` copia y protege la clave pública). Repo montado en `/root/NycTaxiApp`.
4. **Entorno Nix dentro del contenedor:**
   - General: `nix-shell` en la raíz (`default.nix -A shell`, ya horneado en la imagen).
   - Por subcarpeta: `nix-shell api/default.dev.nix` · `nix-shell app/default.dev.nix`
     (variantes `default.prod.nix` **sin crear**: fase 7). Con el pin de
     nixpkgs correspondiente; el primero que se use puede descargar el
     tarball (la imagen solo hornea el pin raíz), y `app/default.dev.nix`
     descarga `chromium` la primera vez (~1,3 GB desde el binario cache).
5. **Validar dentro de ese shell:** `Rscript tests/testthat.R` (en `app/` o en
   `api/`), el mock API, o cualquier chequeo de sintaxis/cargas. Si R falla aquí
   o el shell no levanta, el problema es del entorno Nix, no del código.

Si el flujo falla en cualquier paso: `docker logs nyc-taxi-app` antes de tocar código.

## Cómo arrancar la app a mano (contenedor, cwd = `app/`)
- `nix-shell default.dev.nix --run 'Rscript -e "shiny::runApp(\".\", port = 3838)"'`
  (o `Rscript app/app.R` desde la raíz). Debe imprimir `Listening on ...` en
  **< 3 s** — criterio de la fase 4; medirlo si se toca el arranque.
- Requiere el API real en `127.0.0.1:8000` y `.env` en la raíz (la app lo lee
  con `load_env_file()` solo si la variable no está ya puesta): `TAXI_API_URL`
  y `API_INTERNAL_KEY` son los dos que usa.
- Sin API la app **arranca igual** y falla al primer clic con una notificación:
  los daemons mirai arrancan perezosos en la primera llamada
  (`ensure_daemons()` en `R/utils.R`) y `ggplot2` se adjunta en el primer
  gráfico (`ensure_ggplot2()`); mover cualquiera de los dos al arranque
  devuelve el tiempo a ~4 s y rompe el criterio de arriba.

## Cómo habla la UI con la API
- `app/R/api_client.R` es la **única** ficha que conoce rutas/payloads y debe
  mantenerse sin Shiny: se hace `source()` dentro de los daemons mirai.
- Todo el HTTP pasa por `api_async()` (mirai) + `ExtendedTask` +
  `bind_task_button`; resultados con `task_result()`. Nunca httr2 directo en un
  observer. URL base: `TAXI_API_URL` (defecto `http://127.0.0.1:8000`).
- El estado de la sesión vive en `R/state.R` (`estado`, un `reactiveValues`
  **por sesión**, nunca en globales — §6.1.5): IP del cliente, `resume_code`
  (una sola vez), el `DayState` más reciente, `model_progress` y el resultado.
  `estado_ctx(estado)` construye el contexto de cada llamada.
- El catálogo de los 18 endpoints (`X-Internal-Key`, `X-Resume-Code`, rate
  limit) está en §5.2 y en `contract/openapi.yaml`, que es lo que el cliente
  implementa. `R/modules/mod_results.R` existe como panel mínimo de Results
  (la fase 6 lo amplía con share/feedback/percentil).

## Fuente de verdad y prioridad entre documentos
- **Documento maestro = decisiones de arquitectura; no se edita.** Si el código
  actual diverge del doc, el doc marca la meta y el código el estado actual:
  anotar la diferencia, nunca "corregir" el documento.
- `contract/openapi.yaml` + `contract/share.openapi.yaml` = contrato HTTP
  **autoritativo**; toda implementación nueva se contrasta aquí y se
  revalida con Spectral (0 errores). La UI (`app/R/api_client.R`) ya habla
  con estos endpoints, así que el transitorio `API_CONTRACT.md` fue retirado.
- `docs/REPO_DECISION.md` = ADR monorepo vs. repos separados.

## Repositorio hermano `~/r-projects/NycTaxi` (referencia, solo lectura)
Es el **prototipo original** (paquete R + artículos Quarto) del que este
monorepo porta el código. Úsalo para leer/copiar, **nunca para editarlo** y
**nunca como dependencia** (no aparece en ningún `DESCRIPTION`, `default.nix`
ni Dockerfile de aquí).
- **Fase 3 (ya portada):** `R/simulate_trips.R` → `simulate_trips()` de la API
  (§3 del doc maestro: duración 8h+30 min, viajes on-the-fly, semilla,
  regla WAV `wav_match_flag`) · `R/add_take_current_trip.R` → reglas de
  decisión (`performance_per_hour`, `percentile_75_performance`) ·
  `tests/testthat/test-simulate_trips.R` → base de los tests del port.
- **Fase 2 (ya portada):** `select_zone_with_high_change()` y
  `plot_decision_boundary()` viven inline en
  `investigation-phases/12-shiny-app.qmd` (origen de `/sensitivity`).
- **Fase 9:** `investigation-phases/12-shiny-app.qmd` (24 KB, ya escrito) es
  el artículo candidato a publicar en `angelfelizr.github.io/NycTaxi/`.
- **Prohibido usar** `~/r-projects/NycTaxiPins` y
  `~/r-projects/NycTaxiBigFiles`: no son inputs de este proyecto en runtime,
  build ni tests. Los únicos datos/inputs son `MODELS_DIR` y `DATA_DIR`
  (§15, descargados del release `v0.0.1-data`). Que el compose de ese repo
  monte `../NycTaxiApp` es particularidad suya, no una dependencia nuestra.

## Idioma
- **Todos los archivos nuevos se escriben en inglés** (código, docs, ADRs, CI).
- **La comunicación entre el usuario y el agente es en español.**
- Excepción: `04 - Documento Maestro de Decisiones del Proyecto.md` permanece en
  español, intacto y sin modificar.
