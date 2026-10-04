# AGENTS.md

Este repo es el **monorepo** del "NYC Taxi Decision Simulator". El
`04 - Documento Maestro de Decisiones del Proyecto.md` es la **fuente de verdad**
y **no debe modificarse nunca**. Estructura destino (§1.3): `contract/`, `api/`,
`app/`, `share/`, `infra/`, `tools/`, `integration/`, `nix/`, `docs/`,
`.github/workflows/`. Hoy solo existe la UI Shiny en `app/`: api, share, infra,
contrato OpenAPI, CI y `.env` están por construir.

## Reglas del monorepo (§1.2, no negociables)
- Un solo `.env` en la raíz · un solo `docker-compose.yml` en la raíz (más
  `docker-compose.prod.yml`) · un solo `default.nix` raíz agregador. Sin submódulos.
- **Compose/default.nix por subcarpeta (acordado):** cada servicio puede tener su
  propio `docker-compose.yml` y sus `default.dev.nix` / `default.prod.nix`
  (4 ficheros: `api/` y `app/`, dev y prod) **solo para probarlo de forma
  individual**. Los de la raíz siguen siendo los canónicos de despliegue; nada de
  producción depende de los de las subcarpetas.
- **Nix (§1.2.3 + decisión):** los módulos viven en `nix/` de la raíz:
  `nix/pkgs-api.nix` y `nix/pkgs-app.nix` con **fechas de nixpkgs distintas**
  (API y UI se pinan por separado), más `nix/r-api.nix`, `nix/r-shiny.nix`, etc.
  `default.nix` raíz los importa a todos; los `default.*.nix` de cada servicio
  importan solo los suyos.
- Cambiar un pin invalida solo las capas Docker de ese servicio; cambiar
  `nix/pkgs*.nix` afecta a las capas que lo usen — hacerlo conscientemente.
- Un solo semver y `CHANGELOG.md`; CI con `paths:` por servicio (§8.6).
- **Red y seguridad (§1, §2.4, §5.4, §5.7):** la API solo existe en la red privada
  de Docker; ningún `ports:` para la API. La clave del `.env` es
  `API_INTERNAL_KEY` y **todo** endpoint exige `X-Internal-Key` (403 sin ella);
  `X-Client-IP` solo se acepta junto con la clave válida. CORS limitado (dominio
  propio en prod, `localhost` en dev, bloquear `Origin: null`). Los clientes
  autorizados son `app/` y `share/`.

## Tests: tres paquetes de R separados
- `app/` → tests de **UI** (unitarios de módulos + `shinytest2`).
- `api/` → tests de la **API** (`testthat` + `testcontainers` con Postgres efímero).
- `integration/` en la raíz → paquete R propio de tests de **integración** API↔UI
  (extensión al árbol §1.3; el doc solo contempla `test-contract`, `test-api`,
  `test-shiny`, `test-share` en el CI — añadir `test-integration` al crear el CI).
- Cada paquete tiene su propio `DESCRIPTION` y `tests/` (ver `docs/REPO_DECISION.md`).

## La UI vive en `app/`
`app/` contiene la app Shiny completa: `app.R`, `R/`, `www/`, `tests/`, `dev/`
(mock de la API), `DESCRIPTION`. En la raíz solo viven lo compartido:
`default.nix`, `nix/`, `Dockerfile`, `docker-compose.yml`, `setup.sh`, `.envrc`,
`.Rprofile`, docs y el contrato.
- `app/tests/testthat/helper-load.R` usa `file.path("..", "..")` → resuelve contra
  `app/`; ejecutar los tests con cwd = `app/`.
- `NAMESPACE`, `man/` y `.Rbuildignore` (restos de la plantilla golem) fueron
  eliminados: no reintroducirlos. `DESCRIPTION` documenta dependencias; no es un
  paquete instalable.
- El `.Rprofile` (guardas de Nix que bloquean `install.packages()`) está en la
  raíz y R solo lo carga si el cwd es la raíz.

## Comandos (cwd = `app/` salvo indicación)
- Tests UI: `Rscript tests/testthat.R`. NO `test_check()`/`devtools::test()`:
  no es un paquete instalado; `helper-load.R` hace `source()` de `R/api_client.R`
  y `R/utils.R` a mano.
- Un archivo: `testthat::test_file("tests/testthat/test-utils.R")`.
- Tests de API sin servidor: `httr2::with_mocked_responses()` (`test-api_client.R`).
- Stub local de la API: `Rscript dev/run_mock_api.R` (plumber2, puerto 8000);
  escrito contra la sintaxis de anotaciones de plumber2 y **nunca ejecutado**.
- Contenedor de desarrollo (cwd = raíz): `./setup.sh` (`-np` para no hacer pull).
  Hoy la imagen solo levanta sshd (host :2222, repo en `/root/NycTaxiApp`): es el
  entorno de desarrollo, **no** las imágenes de despliegue del §1.1.

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
     (variantes prod análogas). Con el pin de nixpkgs correspondiente; el primero
     que se use puede descargar el tarball (la imagen solo hornea el pin raíz).
5. **Validar dentro de ese shell:** `Rscript tests/testthat.R` (en `app/`), el
   mock API, o cualquier chequeo de sintaxis/cargas. Si R falla aquí o el shell no
   levanta, el problema es del entorno Nix, no del código.

Si el flujo falla en cualquier paso: `docker logs nyc-taxi-app` antes de tocar código.

## Cómo habla la UI con la API
- `app/R/api_client.R` es la **única** ficha que conoce rutas/payloads y debe
  mantenerse sin Shiny: se hace `source()` dentro de los daemons mirai.
- Todo el HTTP pasa por `api_async()` (mirai) + `ExtendedTask` +
  `bind_task_button`; resultados con `task_result()`. Nunca httr2 directo en un
  observer. URL base: `TAXI_API_URL` (defecto `http://127.0.0.1:8000`).
- `API_CONTRACT.md` = contrato de las 5 rutas mínimas que consume la app hoy; el
  catálogo completo (18 endpoints, `X-Internal-Key`, rate limit) está en §5.2.
  Antes de implementar, confirmar contra el documento maestro.

## Fuente de verdad y prioridad entre documentos
- **Documento maestro = decisiones de arquitectura; no se edita.** Si el código
  actual diverge del doc, el doc marca la meta y el código el estado actual:
  anotar la diferencia, nunca "corregir" el documento.
- `API_CONTRACT.md` gobierna el contrato HTTP vigente de la UI.
- `docs/REPO_DECISION.md` = ADR monorepo vs. repos separados.

## Idioma
- **Todos los archivos nuevos se escriben en inglés** (código, docs, ADRs, CI).
- **La comunicación entre el usuario y el agente es en español.**
- Excepción: `04 - Documento Maestro de Decisiones del Proyecto.md` permanece en
  español, intacto y sin modificar.
