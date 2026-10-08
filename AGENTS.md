# AGENTS.md

Este repo es el **monorepo** del "NYC Taxi Decision Simulator". El
`04 - Documento Maestro de Decisiones del Proyecto.md` es la **fuente de verdad**
y **no debe modificarse nunca**. Estructura destino (§1.3): `contract/`, `api/`,
`app/`, `share/`, `infra/`, `tools/`, `integration/`, `nix/`, `docs/`,
`.github/workflows/`. **Dos extensiones del árbol anotadas** (el §1.3 no las
lista; se registran aquí y en `CHANGELOG.md`, nunca corrigiendo el documento):
`integration/` y `shared/`.
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
en `MODELS_DIR` (suite API y `api/dev/e2e_experiments.sh`
en verde; ver la sección de experimentos). **Fase 4 hecha:** la UI (`app/`)
habla con los endpoints reales del contrato: `mod_setup` con Leaflet
bidireccional, validación con hints, email/marketing, semilla avanzada y el
modal único de `resume_code`; `mod_header`, `mod_confirm_modal` y un
`mod_results` mínimo; estado de sesión en `state.R` (reenvío de `X-Client-IP`);
arranque perezoso de los daemons mirai (< 2 s a "Listening"); mock API en
`app/dev/mock_api.R` con tests unitarios y de flujo `shinytest2` en Chromium.
**Split de dependencias Nix hecho:** `nix/pkgs-app.nix` + `nix/r-app.nix` para
la UI, `nix/test-tools.nix` solo con el navegador de los tests, `system.nix`
de vuelta a lo genérico (sin `chromium`) y `r-dev.nix` sin `devtools`/
`roxygen2` (ver la sección de Nix). **Fase 5 hecha:** `mod_trip_card` (oferta,
mapa con `leafletProxy`, Accept/Reject) y `mod_sensitivity` (selectize
server-side + `renderGirafe`) extraídos de `mod_trips`, que ahora es la
pantalla con sidebar 3/9, KPIs, barra de *pending time* y footer de atajos de
teclado (`www/js/shortcuts.js`); todos los módulos viven en `R/` (§6.2 dibujaba `R/modules/`, ver arriba);
con tests unitarios y de flujo. **Fase 6 (mitad de `app/`) hecha:** `mod_results`
con los 6 KPIs, las 3 curvas, el percentil, la insignia de semilla y los
detalles técnicos + `mod_feedback`; la jornada termina en `POST /finish`
(único sitio que calcula `outcome` y `user_percentile`), y el mock reproduce
la precedencia de §3.10. **Servicio `share/` hecho** (ver su sección): las 3
rutas de `contract/share.openapi.yaml` y arranque verificado.
**Fase 6 entera hecha:** `mod_share` (Download PNG / Copy link / X /
LinkedIn + el segundo prompt de email de §6.5) montado en `mod_results`,
`api_share_email` y el mock de `/share-email`. **Fase 7 hecha:** ver su sección —
`docker-compose.prod.yml`, `infra/`, los3 Dockerfiles multi-stage, los3
`default.prod.nix`, `.github/workflows/ci.yml`, **y las tres imágenes
construidas de verdad y smoke-testeadas**. **Hecho tras la 7:**
`docs/operations/runbook.md` (§8.8), `docs/operations/first-deploy.md`
(checklist de lo que vive fuera del repo), `integration/` (tests de las
  tres descripciones del sistema), **el stack completo verificado de punta a
punta con `infra/scripts/smoke-stack.sh`** y
el **aviso de privacidad** (`app/www/privacy.html`, §9.1, obligatorio antes de
publicar) enlazado desde Setup, el footer y el modal de email, y **R5:**
`health_check.sh` (la API ya no está sin vigilar), `disk_check.sh` ampliado a
los backups y el log estructurado de §11
(`method/path/status/duration_ms/correlation_id/ip_hash`), y **R6.1:**
ADR-0006 + `test-contract-conformance.R`, que valida los cuerpos de respuesta
contra `contract/openapi.yaml` con ajv (y encontró cuatro defectos reales al
primer pase — ver el ADR).
**Pendiente — solo cosas externas:** credenciales SMTP reales + registros
SPF/DKIM/DMARC, secretos de GitHub para desplegar en la VM, la regla de caché
y los DNS de Cloudflare, UptimeRobot, y los dos huecos del release de datos
(ver "Bloqueos del primer despliegue"). Después, fases 8 y 9.

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
  `nix/test-tools.nix` = **solo** lo que las pruebas necesitan: el
  navegador **y** `shinytest2`, fuera de la imagen desde ADR-0007.
  **Sin dependencias huérfanas:** `system.nix` es genérico (R, locales, fuentes)
  y de ahí salió `chromium` (**1,3 GB**: 3701 → 2428 MB de cierre), de modo que
  ninguna imagen que reutilice esa capa herede un navegador que nunca ejecuta;
  `r-dev.nix` perdió `devtools`/`roxygen2` (75 MB: no hacen falta — hay
  `NAMESPACE` pero no roxygen, nada lo genera). El shell raíz excluye `r-api.nix`,
  `r-app.nix` y `test-tools.nix`. **Fase 7:** existen los tres
  `default.prod.nix` (`api/`, `app/`, `share/`); `nix/r-app.nix` acepta
  `withDev = false` para que la imagen no arrastre `r-dev.nix`, y
  `testthat` salió de `nix/r-api.nix` (es la capa de la imagen) para vivir
  en `api/default.dev.nix`.
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

## Tests: cuatro paquetes de R separados
- `app/` → tests de **UI** (unitarios de módulos + `shinytest2`).
- `api/` → tests de la **API** (`testthat` con el **Postgres fijo del compose**
  raíz, no testcontainers — `docs/decisions/0001-*`), Redis real para el
  caché de `/sensitivity` (se salta si no responde). Incluye la **conformidad
  de los cuerpos** con el contrato (ADR-0006):
  `helper-contract.R` compila un ajv por esquema con `jsonvalidate` + `V8`
  y `expect_contract_response()` exige además que el **status** esté
  documentado. `yaml`, `jsonvalidate` y `V8` viven en `api/default.dev.nix`
  y **no** en `nix/r-api.nix` (esa es capa de la imagen), igual que
  `testthat`.
- `share/` → tests del **servicio público**: bot de filtro, HTML, PNG, cliente
  API (httr2 *mockeado*) y Redis; `test-routes.R` arranca el servicio **y un
  stub de la API** en dos procesos hijo con `callr` y les dispara de verdad.
  Redis debe estar en pie (si no, se salta); no necesita la API.
- `integration/` en la raíz → paquete R propio de tests de **integración**
  API↔UI (extensión al árbol §1.3; el doc solo contempla `test-contract`,
  `test-api`, `test-shiny`, `test-share` en el CI — el job `test-integration`
  de `.github/workflows/ci.yml` existe y está guardado por si `integration/`
  vuelve a vaciarse). **Comprueba que las tres descripciones del sistema
  coinciden**: las rutas que `api/plumber.R` registra vs `contract/openapi.yaml`,
  las 3 de `share/R/routes.R` vs `share.openapi.yaml`, y los caminos que
  llaman `app/R/api_client.R` y `share/R/api_client.R` (con `{param}` vs
  `{id}` normalizados.
  - Deja **escrita** una deriva real: §5.2 y el contrato listan 18 endpoints y
    la API registra 16 — `/trips/sample` y `/zones/geojson` no existen y no
    tienen cliente (§6.1.3 hace que la app lea las zonas del volumen). El test
    exige que ese diferencial sea exactamente esa pareja, así que falla en
    cuanto alguien los implemente o los borre del contrato.
- Los cuatro (`app/`, `api/`, `share/`, `integration/`) tienen su
  `DESCRIPTION` y su `tests/` (ver `docs/REPO_DECISION.md`).

## `mod_share`: los botones y el email de Results (6.5, 7.3, 7.4)
- `app/R/mod_share.R` vive **dentro** de `mod_results` (igual que
  `mod_feedback`): `mod_share_ui(ns("share"))` + `mod_share_server("share",
  estado)`, así que los ids son `results-share-*`.
- **Los tres enlaces son `<a>` con `href="#"` y el servidor los apunta** cuando
  `estado$share_token` existe (mismo truco que el color de vs-policy). §6.1.1
  prohíbe `renderUI` para estructura, y un `<a>` de verdad conserva la
  activación del usuario: X/LinkedIn abren pestaña en vez de ser bloqueadas,
  y se pueden abrir con clic central. `shinyjs::runjs` hace el trabajo **dentro
  del clic** y `dataset.shareReady` evita volver a cablear.
- Cada clic emite `{"event":"share_click","channel":"..."}` a stderr vía
  `log_event()` (`app/R/utils.R`), una línea JSON por evento (7.4).
- **`ShareEmailRequest.email` es opcional, pero el cuerpo nunca puede faltar**:
  este plumber2 solo despacha un POST con cuerpo JSON. `api_share_email()`
  manda `list()` con nombres (serializa a `{}`) cuando no hay dirección.
- `SHARE_BASE_URL` (defecto `https://nyctaxiapp.angelfeliz.com`) es la base
  pública: Results construye `{base}/share/{token}`. En dev apunta al servicio.
- El **segundo prompt** (6.5) aparece solo si `estado$email` está vacío —
  `mod_setup` lo guarda en el observer de creación, y un día reanudado con
  `?exp=` nunca lo tuvo.

## La UI vive en `app/`
`app/` contiene la app Shiny completa: `app.R`, `R/`, `www/`, `tests/`, `dev/`
(mock de la API), `DESCRIPTION`. En la raíz solo viven lo compartido:
`default.nix`, `nix/`, `Dockerfile`, `docker-compose.yml`, `setup.sh`, `.envrc`,
`.Rprofile`, `README.md`, `CHANGELOG.md`, `LICENSE`, `.env.example`, docs y
`contract/`.
- `app/tests/testthat/helper-load.R` usa `file.path("..", "..")` → resuelve contra
  `app/`; ejecutar los tests con cwd = `app/`.
- **`app/` es un paquete** (`taxiapp`): `DESCRIPTION` + `NAMESPACE`
  (`exportPattern` sin `import()`, sin S3 methods) + `R/` **plano** — ADR-0007.
  La imagen lo instala con `R CMD INSTALL` y `app.R` hace `library()`; un shell
  de desarrollo no lo tiene instalado y cae en `pkgload::load_all()`. Añadir un
  módulo ya no exige tocar nada: se suelta en `R/`.
- **§6.2 dibuja `R/modules/`, y eso ya no existe** (R ignora las subcarpetas de
  `R/`, así que un paquete no puede tenerlas). Divergencia anotada en
  `CHANGELOG.md`; el documento no se toca.
- **`app/R/_disable_autoload.R` no es código**: es la marca que hace que
  `shiny::loadSupport()` deje de fuentear `R/` en el entorno donde vive
  `app.R`. Sin ella habría dos copias de cada objeto — entre ellos
  `constants_state`, que tiene que ser exactamente uno. No renombrar.
- En las funciones `*_ui` se usa `ns <- NS(id)`; en el servidor la única
  forma es `session$ns(...)` — `ns` no existe ahí y falla en runtime.
- El `.Rprofile` (guardas de Nix que bloquean `install.packages()`) está en la
  raíz y R solo lo carga si el cwd es la raíz.
- **`app/www/privacy.html`** (§9.1, obligatorio antes de publicar): página
  estática, sin JS, enlazada desde el bloque de email de `Setup`, desde el
  `footer` de `page_navbar` y desde el modal de email de `mod_share`. Es la
  única página de `www/` que no puede leer `shared/brand.yaml`, así que el
  hex va literal con un comentario. `test-privacy.R` la obliga a cubrir los seis puntos de §9.1 y a que los tres enlaces existan.

## Comandos (cwd = `app/` salvo indicación)
- Tests UI: `nix-shell default.dev.nix --run "Rscript tests/testthat.R"`
  (unit + flujo). **El recuento vive en la salida y en CI, no aquí.**
  NO `test_check()`/`devtools::test()`: `helper-load.R` hace `load_all()`
  (o `library(taxiapp)` cuando `R_COVR` está, que es lo que hace covr — sin
  esa rama la cobertura saldría 0). En el shell **raíz** todo pasa salvo el test de flujo:
  ese shell no lleva `test-tools.nix`, y se salta con un mensaje que apunta al
  shell correcto.
- Un archivo: `testthat::test_file("tests/testthat/test-utils.R")`.
- **Cobertura de §10** (cwd = `api/`):
  `nix-shell default.dev.nix --run "Rscript dev/coverage.R"`. Está en `dev/`
  y no en `tests/` porque covr ejecuta todo `.R` de `tests/`: un script de
  cobertura ahí se mediría a sí mismo. Exporta `TAXI_API_DIR` (los tests
  corren sobre la **copia instalada** en un árbol temporal y sin eso `..` no
  apunta al repo) y se exigen **ambos** umbrales de §10:
  `COVERAGE_FAIL_UNDER=60` (global) y `COVERAGE_FAIL_CRITICAL=1` (100 % en
  cada uno de los siete ficheros críticos).
- Tests del **cliente** API sin servidor: `httr2::with_mocked_responses()`
  (`app/tests/testthat/test-api_client.R`) — no confundir con los de la API.
- Tests del **servicio share** (cwd = `share/`):
  `nix-shell default.dev.nix --run "Rscript tests/testthat.R"`. Redis tiene
  que estar en pie; si no, `test-cache.R` y
  `test-routes.R` se saltan. No necesita la API: `test-routes.R` arranca un
  stub suyo. Arrancarlo a mano (cwd = raíz):
  `nix-shell share/default.dev.nix --run "Rscript share/plumber.R"` →
  escucha en `SHARE_PORT` (8020) e imprime la URL base y el RSS.
- **Release de datos**: `./infra/scripts/make-manifest.sh` escribe
  `SHA256SUMS` para los 6 ficheros (viven en `models/` **y** `data/`, así que
  `sha256sum *` solo cubriría la mitad); `./infra/scripts/test-fetch-assets.sh`
  los verifica de punta a punta con ficheros inventados (sin red, sin `.env`).
  Subir `SHA256SUMS` + `ReferenceDistribution.qs2` al release: ver
  `docs/operations/first-deploy.md` §1.
- **SMTP en desarrollo**: el compose de dev trae `mailpit` y fija
  `SMTP_URL=smtp://mailpit:1025`, `TAXI_API_URL` y `SHARE_URL` en el
  contenedor (gana `environment:` sobre `env_file`, así que `.env` sigue
  valiendo para producción). Lee lo enviado en `http://127.0.0.1:8025`.
- **Monitor de servicios** (raíz o VM, necesita Docker):
  `./infra/scripts/health_check.sh` → 0 si api/share/Postgres/Redis están
  bien, 1 si no (correo con cooldown de 6 h). `disk_check.sh` cubre disco
  **y** backups: alerta si el dump más reciente pasa de 25 h, que es lo que
  descubre que el cron se cayó.
- **Smoke del stack** (raíz, necesita Docker y los modelos en `MODELS_DIR`):
  `./infra/scripts/smoke-stack.sh` → sale con 0. `SMOKE_KEEP=1` lo deja
  corriendo; es la única comprobación de §10 que existe hoy.
- Tests de **integración** (cwd = `integration/`):
  `nix-shell default.dev.nix --run "Rscript tests/testthat.R"` (su propio
  shell, `integration/default.dev.nix`: solo `testthat` + `yaml`; el shell
  raíz compila seis sets de paquetes que estos tests no tocan).
  No necesita ningún servicio: son las tres descripciones del
  sistema (contrato ↔ rutas registradas ↔ caminos de los clientes) mirándose
  una a la otra.
- Test de flujo (`test-shinytest2.R`, fases 4-6): levanta `dev/mock_api.R` en un
  puerto aleatorio, arranca la app real en Chromium headless y recorre
  Setup → semilla → modal → Trips → todas las decisiones hasta cerrar la
  jornada → Results → modal de feedback, más el reenvío de `X-Client-IP`.
  Requiere `chromium` (`nix/test-tools.nix`, presente en
  `app/default.dev.nix` **no** en el shell raíz) y `NOT_CRAN=true`
  (`AppDriver` se niega a correr si testthat cree que estamos en CRAN; el
  shell y el propio test lo fijan).
- Tests de la API (contenedor, cwd = `api/`): `nix-shell default.dev.nix` y
  `Rscript tests/testthat.R`. **Pasa con y sin modelos y sin datos**: con
  `TAXI_MODELS_DIR=/nonexistent TAXI_DATA_DIR=/nonexistent` solo se salta
  `test-sensitivity.R` ("dataset not mounted"). **El CI corre sin modelos**
  así que no descarga los 534 MB del release. Requiere Postgres y Redis reales
  del compose raíz — levantar `docker compose up -d` antes.
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
  **Los tests de CI corren dentro de esta misma imagen**, publicada como
  `ghcr.io/angelfelizr/nyc-taxi-dev:latest`: los cuatro jobs de test hacen
  `docker pull` + `docker run --network host` con el repo montado en
  `/root/NycTaxiApp`. En el runner no se instala Nix — así CI y un portátil
  no pueden discrepar sobre el filesystem, la versión de Nix ni el store
  (verificado localmente: dentro de la imagen, `nix-shell` da los mismos
  recuentos que fuera).
  - **Se construye y se sube AQUÍ, no en CI** (`nix/` cambia mucho menos que
    el código y un runner no debería pagar por recompilar el entorno).
    Desde la raíz: `./infra/scripts/dev-image.sh build` (hace
    `docker build --label nix-hash=…` + `docker push`). **Ojo:** cambiar un
    fichero de `nix/` invalida las capas siguientes y Nix recompila desde
    source — el build cuesta **horas**, no minutos; cuenta con ello antes de
    tocar `nix/`.
  - **CI se niega a testear contra una imagen desactualizada:**
    `dev-image.sh check` compara la etiqueta `nix-hash` de la imagen con la
    de este checkout y falla **antes** de ejecutar un solo test, diciendo qué
    comando correr. Un run contra pins distintos aprueba o falla por un motivo
    que no está en el commit.
  - **La imagen hornea los shells que los tests usan** (capa 9d del
    `Dockerfile`: `api/default.dev.nix` y `share/default.dev.nix`), para que
    `nix-shell` no compile nada en el runner. El de la UI **no** va horneado
    porque arrastraría `nix/test-tools.nix` (chromium, 1,3 GB): el test de
    flujo lo baja del cache binario al primer uso.

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
  distribución de referencia. **El % de `setup` también**: `setup_progress`
  (migración `002`) lo publica el hijo cada 5 pasos con
  `AND status = 'setup'` (ADR-0009), y `/state` lo lee de ahí con `FOR SHARE`
  en vez de contar filas — `traj_jobs` no se lee nunca para construir la
  respuesta, solo para recoger zombies. Los tests fijan `API_EXPERIMENTS_SYNC="1"`
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
     · `nix-shell share/default.dev.nix` (y las variantes `default.prod.nix`,
     que dejan fuera las herramientas de test). Con el pin de
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
- **Presupuesto actual ~2,6 s** (medido: 2,52-2,71 s en 5 arranques cálidos;
  el **primer** arranque tras entrar al shell es frío y marca 3,9-4,9 s — es
  R yendo a disco, no la app; sourcear todo `app/R/` con `shared/` cuesta
  0,15-0,18 s). La mayor
  partida es `ggiraph::girafeOutput` (~1,1 s: al construir la UI carga los
  namespaces de ggplot2 y ggiraph), así que no se adelante ninguna carga de
  namespace sin volver a medir.
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
  implementa. `R/mod_results.R` es la pantalla final (6 KPIs,
  percentil, insignia de semilla); la fase 6 pendiente es **el envío real por
  SMTP** — los botones y el `share/` ya existen y se documentan más abajo.
- **El log JSON de §11 no se puede construir con `access_log_format`.** Ese
  formato es una plantilla cli/glue: sustituye `{...}` y **vuelve a pasar el
  resultado por cli**, así que cualquier valor con llave (todo JSON) se toma
  por código R y el servidor muere con `Could not parse cli {} expression`.
  Tres intentos, tres crashes. La línea se arma en `access_logger()` con
  `sprintf`, y el formato queda en `STATUS={response$status}` — que además es
  el único sitio donde el status final es fiable (`res` y `request$response`
  llegan tarde: un 404 logueado como 200). El `correlation_id` se
  **formatea** del reloj, no se calcula con `as.numeric(Sys.time())*1e6 %% 1e9`:
  un double no guarda 15+6 dígitos y dos peticiones seguidas chocaban.
- **Un fallo NUNCA rechaza la promesa.** `api_async()` resuelve con
  `list(value=...)` o `list(failure=<mensaje de la API>)`, y `task_result()`
  convierte el segundo en notificación + `NULL`. No lo cambies: Shiny convierte
  una promesa rechazada en `shiny.silent.error` **con el mensaje vacío**, así
  que `task_result()` no podría distinguirlo del "todavía no se ha invocado"
  y re-lanzaría en silencio — que es exactamente lo que pasaba hasta que el
  test de §10 lo pilló. Los 7 callers hacen `res <- task_result(t);
  if (!is.null(res)) ...`, así que `NULL` en fallo los deja intactos.
  `promises::promise_resolve` cubre el caso de workers que no arrancan (ahí no
  cabe un mirai).
- **La jornada solo termina en `POST /finish`** (§4.6: `outcome` y
  `user_percentile` se calculan "siempre en el servidor"). `mod_trips` lo
  llama cuando `shift_over()` ve `pending_hours <= 0`; nada más cambia el
  estado a `finished`, y el mock tampoco auto-cierra. **Ese `POST` envía
  `{}`**: la ruta no declara `requestBody` y la API real lo acepta con o sin
  cuerpo, pero este plumber2 solo despacha una ruta POST si la petición lleva
  cuerpo JSON (sin él cae al catch-all); `api/dev/e2e_experiments.sh` ya
  enviaba `-d '{}'` por el mismo motivo.

## El servicio público `share/`
- **`POST /render-card` (interna, ADR-005).** La API empuja el payload en vez
  de que `share/` lo pida: plumber2 atiende **una petición a la vez** en el
  proceso R, así que un GET de vuelta bloqueaba contra el propio handler que
  esperaba la tarjeta (medido: `GET /health` parado **10 129 ms**). El payload
  es el mismo documento de `GET /share-data` — lo construye
  `share_data_payload()`, el único builder de los dos caminos — y exige
  `X-Internal-Key`. **Divergencia con §5.10** (que no la lista), anotada en
  `CHANGELOG.md`; no llega de Internet porque Nginx solo proxya `/share/` y
  `/waitlist` y el puerto es `expose:`, no `ports:`.
- **Es el único servicio expuesto a Internet** (§5.10, §7): por eso no lleva
  credenciales de base de datos ni modelos — solo habla con
  `GET /share-data/{token}` y `POST /waitlist` de la API privada, con
  `X-Internal-Key` + `X-Client-IP`. `TAXI_API_URL` del `.env` apunta a
  `http://api:8000` (red Docker), así que **fuera de compose hay que pasarlo
  a mano** (`TAXI_API_URL=http://127.0.0.1:8000`); si no, la llamada no
  resuelve y el servicio responde 503 — que es exactamente el fail-safe
  previsto, no un bug.
- **`plumber2::format_png()` es un serializador de GRÁFICOS:** abre un
  device, captura lo que se dibuje y **descarta `response$body`**. La tarjeta
  salía en blanco (1,8 KB) con el handler ya habiendo renderizado 51 KB de
  píxeles reales. Por eso **todas** las rutas se registran con
  `serializers = application/json` (que es lo que la contrato pide para cada
  error) y cada éxito cambia de tipo **dentro del handler** con
  `response$set_formatter("image/png" = function(x) x, default = "image/png")`
  (o `"text/html" = reqres::format_plain()`). Dejarlo a la negociación de
  plumber2 haría que `Accept: */*` eligiera la imagen y escondiera el
  documento de error. El formatter del PNG es una identidad: los bytes ya los
  produce `share_png()`.
- **`httr2::req_perform()` lanza en 4xx/5xx por defecto**, así que sin
  `is_error = ~ FALSE` cada status real cae en el `tryCatch` y la página
  contesta 503 para un token desconocido. `api_request()` lo fija en **una
  sola** llamada a `req_error()` (guarda `is_error` y `body` a la vez;
  llamarlo dos veces pisa el primero).
- El orden de registro importa: `/share/<token>.png` **antes** que
  `/share/<token>`, o el patrón padre se traga el sufijo. Ambos patrones
  funcionan (verificado), y `api_any("//*")` cierra la cola.
- `share/R/routes.R` expone `share_api()` para que los tests construyan la
  app sin llamar a `api_run()`. **Nunca pases un objeto `api` de plumber2 de
  un proceso a otro**: los closures/environments no sobreviven bien y todo
  devuelve 500; el hijo debe hacer `source()` y construirlo.
- La plantilla del stub que usan los tests (`helper-boot.R`) entrega **listas**,
  nunca JSON ya serializado: el serializer es el que codifica, y pasar texto
  envuelve el documento entero en una cadena JSON.
- **Nunca sondear un puerto con `socketConnection(server = TRUE)`**: R se
  bloquea en `accept()` aunque `blocking = FALSE`. `free_port()` lee
  `/proc/net/tcp` (estado `0A` = LISTEN) — exacto y sin bloquear.

## `shared/` — la configuración visual compartida (extensión del árbol §1.3)
- **Qué hay:** `shared/curves.yaml` (las 3 curvas: orden, etiqueta, color) y
  `shared/brand.yaml` (`primary`, `primary_dark`), leídos por **ambos**
  frontends a través de `shared/load.R` (el único código del directorio).
  El porqué y las alternativas descartadas: `docs/decisions/0003-shared-visual-config.md`.
- **§1.3 no lista `shared/`** (tampoco `integration/` ni `AGENTS.md`): divergencia
  anotada aquí y en `CHANGELOG.md`, **nunca corrigiendo el documento**.
- **Orden de carga (crítico en `app/`):** Shiny fuentea `R/*.R` **antes** del
  cuerpo de `app.R` (verificado con un probe) y `strings.R` construye sus
  `label_curve_*` con `curve_labels()`. Por eso existe `app/R/shared_config.R`:
  busca `shared/load.R` por candidatos y se fuentea **dentro** de `R/`. Solo
  funciona porque `R/` se fuentea en orden alfabético
  (`constants` → `shared_config` → `state` → `strings`): **no renombrar
  `shared_config.R` a algo que pase de `strings.R`, ni sacarlo de `R/`.**
- **`shared/load.R` valida, YAML no:** no hay esquema. `validate_curves()` y
  `validate_brand()` exigen 3 series en orden `user, policy, baseline`, etiquetas
  no vacías ni repetidas, colores `^#[0-9a-fA-F]{6}$` únicos y
  `primary ≠ primary_dark`, y fallan con mensaje legible. Están **exportadas a
  propósito** para que ambos test suites las alimenten con basura.
- **Gotcha:** los colores van **entrecomillados**. `colour: #6d5dfc` sin comillas
  abre un comentario YAML y parsea a `null` (el validador lo detecta).
- **`shared_dir()` resuelve por candidatos** (`SHARED_DIR` → `./shared` →
  `../shared` → `../../shared` → `/srv/nyctaxi/shared`), el mismo truco que
  `app_data_dir()`. `SHARED_DIR` es la perilla que usará la fase 7.
- **Nix:** `nix/r-shared.nix` (solo `yaml`), importado por `nix/r-app.nix` y por
  `share/default.dev.nix`; el shell raíz lo recibe solo (auto-descubre `r-*.nix`).
  **Fase 7:** el `Dockerfile` necesita la capa **9c** (`COPY` antes de la 10, o
  el shell horneado sale sin `yaml`) y las imágenes deben `COPY shared/`.
- **No rompe la frontera de `docs/REPO_DECISION.md`:** esa regla ("la app nunca
  importa código de la API") protege `api/`↔`app/`; `shared/` es
  **configuración de datos** que leen dos frontends, no código de un servicio.
- **Consumidores:** `strings.R` (alias `label_curve_*`, por §6.2), `mod_results`,
  `theme.R`, `mod_setup`, `mod_trip_card`, `mod_sensitivity` (marca) y
  `share/render_png.R` + `share/render_html.R`. El hex literal ya **no existe**
  en `app/R/` ni en `share/R/`: `grep -rn "6d5dfc\|8b7dff" app/R share/R` debe
  volver vacío.

## Fase 7: infra y despliegue (§1.0, §1.1, §8)

**Las tres imágenes se han construido y arrancan** (ver "Las imágenes, de
verdad"). Nada se ha desplegado todavía: eso necesita los secretos de GitHub y
la VM. Lo que sigue es lo que existe y cómo se verificó.

- **`docker-compose.prod.yml` (raíz) es un fichero INDEPENDIENTE**, no un
  override. Compose **suma** `ports:` y `networks:` al apilar ficheros, así
  que `-f docker-compose.yml -f docker-compose.prod.yml` habría publicado
  2222/5432/6379 en producción, justo lo que §9.3 y el smoke test de fase 7
  prohíben (`docker ps` solo puede publicar 80 y 443). Se levanta con
  `docker compose -f docker-compose.prod.yml up -d`.
  - Las tres redes llevan **`name:` fijado**: sin eso compose las renombra a
    `nyctaxi_nyctaxi_api_net` y el `container-network` de ShinyProxy no la
    encuentra (§1.0 las llama `nyctaxi_*_net`).
  - Límites de §1.1, `shm_size: 2g` en la API (el `mori` hace mmap en
    `/dev/shm`, 119 MB), `logging json-file 500m×3`, `restart: unless-stopped`
    y `ENV=production` (§5.7: el `.env` es compartido con dev).
- **`infra/nginx/nginx.conf`** (+ `html/capacity-full.html`, `snippets/`):
  solo enruta a ShinyProxy y a `share`; `/api/` → 404; `proxy_intercept_errors`
  + `error_page 503` → `capacity-full.html` (servido con `internal;`, si no
  volvería a entrar en `location /` y se proxearía a ShinyProxy); 10 r/s para
  `/share/` y `/waitlist`; `set_real_ip_from` con los rangos de Cloudflare.
  **`nginx -t` pasa sin avisos** — ojo: `text/html` en `gzip_types` es
  redundante y nginx avisa.
- **`infra/shinyproxy/application.yml`** (§8.3): `max-total-instances: 10`,
  `allow-container-re-use: true`, `container-network: nyctaxi_api_net`, el
  volumen de datos en solo lectura y las tres variables que el contenedor
  Shiny necesita (`TAXI_API_URL`, `API_INTERNAL_KEY`, `SHARE_BASE_URL`).
- **`infra/scripts/`** (los cuatro pasan `shellcheck`):
  `backup.sh` (§8.5: `pg_dump -Fc`, sha256, retención 28 d, `/backups` 700),
  `restore_test.sh` (restaura en un contenedor desechable y compara el nº de
  tablas — un backup que nadie ha restaurado no es un backup),
  `disk_check.sh` (cron horario, correo SMTP si ≥80 %, cooldown de 6 h) y
  `fetch-assets.sh` (§4.5: baja del release y **verifica SHA-256**, idempotente,
  **aborta sin tocar nada** si la verificación falla).
- **`.github/workflows/ci.yml`** (§8.6): `test-contract` (spectral en docker),
  `test-api` (Postgres y Redis como *service containers* — ADR 0001, no
  testcontainers), `test-shiny`, `test-share`, `test-integration` (guardado:
  `integration/` sigue vacío), `build-{api,shiny,share}` → GHCR y `deploy`.
  Filtrado por servicio con `dorny/paths-filter`. Los builds van en
  `ubuntu-24.04-arm` porque la VM es ARM y un closure de Nix bajo QEMU no cabe
  en un job. **Validado con `actionlint` (0 errores); nunca se ha ejecutado.**
- **`api/Dockerfile`, `app/Dockerfile`, `share/Dockerfile`**: multi-stage sobre
  `nixos/nix:2.35.2`. Etapa 1 junta el *closure* de Nix (`nix-store -qR`) y lo
  tarballa; etapa 2 lo extrae y copia los enlaces `/opt/*`. El layout
  `WORKDIR /app` + `COPY <svc> /app/<svc>/` + `COPY shared/ /app/shared/` no
  es capricho: `root` se calcula como el padre del servicio y
  `R/shared_config.R` busca `../shared`. **`docker build --check` pasa en los
  tres; no se han construido.**
- **`api|app|share/default.prod.nix`** (las variantes que faltaban) y
  **`.dockerignore`**.

### Las imágenes, de verdad

Construidas en el host con `docker build -f <svc>/Dockerfile .` (el contenedor
de desarrollo **no** lleva Docker; ahí solo hay sshd y el repo montado):

| Imagen | Tamaño | Arranque verificado |
|---|---|---|
| `ghcr.io/angelfelizr/nyc-taxi-share:test` | 4,23 GB | `Listening … RSS 199 MB` (límite de §1.1: 256 MB), `/health` 200, `/share/<junk>` 503 JSON |
| `ghcr.io/angelfelizr/nyc-taxi-api:test` | 4,83 GB | `Listening … RSS 373 MB`; sin modelos/DB/Redis degrada con mensajes en vez de morir (warmup en `tryCatch`) |
| `ghcr.io/angelfelizr/nyc-taxi-shiny:test` | 5,22 GB | `Listening on :3838`, `GET /` 200 y **`GET /privacy.html` 200 con el enlace presente dos veces** (Setup + footer) |

- Los builds tardan ~10 min (share), ~45 min (api) y ~15 min (app) porque el
  store del contenedor de build está vacío y **compila los paquetes R desde
  source**: el cache de `rstats-on-nix.cachix.org` no cubre este pin. El caché
  de BuildKit lo amortiza entre runs.
- **Ojo con `nix/system.nix`:** cambiarlo invalida la capa `COPY nix/`, que va
  antes de los `nix-build` de los paquetes R, así que **recompila todo** (~70
  min las tres). Mantenerlo mínimo (R, locales, fuentes, `curl`). Etiquetar
  bien: el script de build debe producir `nyc-taxi-shiny`, no `nyc-taxi-app`.
- El `app` arrancando es también la prueba de que `shared/load.R` se resuelve
  dentro de la imagen: sin `shared/` las `label_curve_*` de `strings.R`
  fallarían antes del primer `Listening`.

### Endurecimiento (ADR-004)

- **Los 6 servicios del compose** llevan `cap_drop: [ALL]` con un `cap_add`
  explícito, `pids_limit` y `no-new-privileges`, y **`read_only: true`** con un
  `tmpfs` por lo que cada uno escribe. Nada de esto estaba en el doc: §1.1
  fija RAM y CPU, no capacidades.
- **Las 3 imágenes corren como `USER 65534:65534`** con `HOME=/tmp`. La base
  Nix no tiene `useradd` y `/etc/passwd` es un symlink al store, así que una
  id numérica es lo portable; `id` dentro del contenedor da `nobody` y
  `/health` sigue en 200.
- **El healthcheck de la API es `curl`, no `Rscript`** (arrancar R cada 30 s
  en un contenedor de 1,5 GB). `curl` vive en `nix/system.nix` y no en
  `/root/.nix-profile`, que un usuario no-root no puede atravesar; la clave va
  como `$$API_INTERNAL_KEY` para que `docker inspect` no la muestre.
- **CSP solo en las páginas estáticas**: `script-src 'none'` en `/share/*` y
  una política cerrada en `capacity-full.html`. **La de `/` sigue pendiente**:
  un CSP mal puesto rompe Shiny en silencio y el smoke no tiene navegador.
  Los headers van en `snippets/security-headers.conf` porque nginx **no**
  hereda `add_header` hacia una location que define el suyo.
- **`/var/run/docker.sock` se queda en ShinyProxy** y los contenedores Shiny
  efímeros no se pueden endurecer desde el compose (§8.3 no expone esa
  opción). Ambos están registrados como riesgo aceptado en el ADR.

### Peso de las imágenes (seguimiento, no bloquea)

**Medido, y no era lo que decía este texto.** El cierre de `nix/system.nix`
son 2608 MB, pero la expresión solo declara 10 paquetes: la toolchain no está
en ella, está en la **salida de `R`**, que referencia `openjdk` (573 MB),
`gfortran` (339), `gcc` (284) y `python3` (144) porque son sus `buildInputs`.
Separar una expresión de Nix no los saca.

- **Hecho (ADR-0008):** las tres imágenes construyen
  `nix/system-runtime.nix` = `system.nix` sin `nix`. El cierre baja
  2608 → 2364 MB, pero **la imagen real baja ~70 MB** (share 4,3 → 4,23;
  api 4,9 → 4,83; shiny 5,32 → 5,22): la suma de `du` por ruta de store
  cuenta dos veces los ficheros enlazados en duro con lo que se queda. Los shells de desarrollo siguen con `system.nix` (ahí es donde
  se ejecuta `nix`), y la única diferencia entre ambos es un binario que no
  se usa, no un comportamiento — por eso no crea asimetría test/prod.
- **Descartado:** reescribir R con `removeReferencesTo` para esos 1,34 GB
  (proyecto aparte: hay que revalidar `R CMD INSTALL` y el arranque de R, y
  quitar `gcc` rompería el primer paquete con código compilado). §1.1 limita
  la **RAM**, no el tamaño de imagen, así que nada lo exige.
- §1.1 sigue sin incumplirse; los push de GHCR son lo lento.

### El smoke del stack

**`./infra/scripts/smoke-stack.sh`** levanta el stack de producción en el
portátil (`docker-compose.prod.yml` + `docker-compose.smoke.yml`) y comprueba
lo que los parsers no pueden: §10(a) `/api/health`→404 por el borde, §10(b)
solo 80/443 publicados, §10(c) un contenedor en `nyctaxi_api_net` ve
`api:8000` pero **no resuelve** `postgres`/`redis`, §10(d) `GET /health` sin
`X-Internal-Key`→403 contra el router real, §10(e) `share` sin `POSTGRES_*`,
`GET /`→200 (Nginx→ShinyProxy), `GET /share/<desconocido>`→404
`application/json` (borde→share→API), §8.2 `error_page 503`→`capacity-full.html`,
`/.well-known/security.txt`→200 y `script-src 'none'` en la CSP de `/share/*`.
Sale con 0 o con 1.

- **El overlay no toca nada fuera del repo:** remapea `/models` y `/data` a
  los directorios de `.env` y cambia `/etc/letsencrypt` por un certificado
  autofirmado en `/tmp`. El compose de producción conserva
  `/srv/nyctaxi/...` para la VM. `SMOKE_KEEP=1` deja el stack levantado.
- **`NYCTAXI_TAG`** (`latest` por defecto, `test` en el smoke) permite que el
  mismo compose sirva para las imágenes de CI y para las locales; lo interpola
  también `application.yml` para la imagen de Shiny.
- **No abre una sesión Shiny**, así que no prueba el WebSocket de una sesión
  real ni el volumen de datos dentro del contenedor Shiny — eso es fase 8.
  Sí afirma que Nginx tiene `proxy_set_header Upgrade` configurado.
- Seis bugs de la fase 7 los encontró este script (ver `CHANGELOG`, sección
  Fixed): `env_file` en `share`, healthcheck sin clave, `proxy.max-instances`
  que rompía el arranque de ShinyProxy, `shm_size` mayor que `mem_limit`,
  SSH dev en `0.0.0.0` y `app_data_dir()` sin conocer `/app/data`.

### Bloqueos del primer despliegue (fuera de este repo)

**Todo lo demás que no puede hacerse desde aquí está en
`docs/operations/first-deploy.md`**: secretos de GitHub, la VM, DNS
(SPF/DKIM/DMARC), la regla de caché de Cloudflare y el monitor de
disponibilidad — con qué crearlo y cómo verificarlo. Dos bloqueos viven en el
propio repo, en el release de datos:

- El release **`v0.0.1-data` no publica `SHA256SUMS`** → `fetch-assets.sh`
  aborta siempre. Es lo que §4.5 pide, pero hay que subir el manifiesto
  (`cd <ficheros> && sha256sum * > SHA256SUMS`).
- El release **no tiene `ReferenceDistribution.qs2`** → `/finish` responde 503
  sin él (ver "Experimentos"). Se genera con
  `tools/build_reference_distribution.R` (~75 min) y hay que subirlo **con** su
  hash.

### No ejecutable desde aquí

Las imágenes se construyen localmente (arriba), pero **pushearlas a GHCR es
tarea de CI**; desplegar en la VM necesita los secretos `VM_HOST`, `VM_USER` y
`VM_SSH_KEY`; la regla de caché de `/share/*.png`, los registros SPF/DKIM/DMARC
y el monitor de disponibilidad viven en dashboards; y el swap de 2 GB de la VM
(§1.1) es un ajuste de la consola de Oracle. Todos ellos, con qué crearlos y
cómo verificarlos, están en `docs/operations/first-deploy.md`.

### Anotación sobre §1.0

§1.0 dice que ShinyProxy "no recibe `API_INTERNAL_KEY`", pero §8.3 inyecta
`${API_INTERNAL_KEY}` en los contenedores que él crea — sin el valor en su
entorno el inyectado saldría vacío y toda petición de la UI devolvería 403.
Se interpreta como "no es un cliente de la API". Divergencia anotada en
`CHANGELOG.md`; el documento no se toca.

### Seguimiento pendiente

- **Peso de las imágenes:** ver "Peso de las imágenes" arriba — ya medido;
  la parte alcanzable sin tocar R está hecha (ADR-0008) y la de R queda
  anotada.
- ~~`shinytest2` en el set de runtime de la UI~~ — resuelto (ADR-0007): vive
  en `nix/test-tools.nix` junto al navegador. Ojo: `app/default.dev.nix` tiene
  que nombrarlo en `R_LIBS_SITE`, o R no lo ve y el test de flujo se salta.

## Fuente de verdad y prioridad entre documentos
- **Documento maestro = decisiones de arquitectura; no se edita.** Si el código
  actual diverge del doc, el doc marca la meta y el código el estado actual:
  anotar la diferencia **en `CHANGELOG.md`** (y en AGENTS si afecta a la
  estructura), nunca "corregir" el documento. Precedentes: el create asíncrono
  con §4.6, `shared/` con §1.3 y §6.4.
- `contract/openapi.yaml` + `contract/share.openapi.yaml` = contrato HTTP
  **autoritativo**; toda implementación nueva se contrasta aquí y se
  revalida con Spectral (0 errores). La UI (`app/R/api_client.R`) ya habla
  con estos endpoints, así que el transitorio `API_CONTRACT.md` fue retirado.
- **Dónde va una decisión nueva:** `docs/decisions/README.md` tiene la
  taxonomía completa (tradeoff → ADR · divergencia con el doc → CHANGELOG ·
  operativo → `docs/operations/` · superficie HTTP → `contract/` · cómo
  trabajar aquí → AGENTS). Dos reglas que van con ella: **un ADR se escribe en
  el mismo commit que la decisión** (§18 del doc planificó 26 y solo existe
  `REPO_DECISION.md`, precisamente porque esta regla no existía) y la sección
  `Alternatives` de la plantilla **es obligatoria** — un ADR sin ella guarda
  una conclusión en vez de un razonamiento.
- **AGENTS no lleva cifras que caducan:** ni recuentos de tests ni totales de
  nada que cambie al añadir un test. El recuento vive en la salida de CI. Si
  una frase necesita un número para ser útil, el número no va aquí.
- `docs/REPO_DECISION.md` = ADR monorepo vs. repos separados.
- **`docs/PLANS.md` = el plan vivo**: qué está hecho, qué queda y por qué
  (conversión a paquetes, R7, los dos trabajos pendientes que aún no tienen
  ADR). No es una decisión, solo el camino — se actualiza al cambiar o
  entregarse un plan, para que una sesión perdida no se lleve el To Do.

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
