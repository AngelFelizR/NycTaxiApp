## NYC Taxi Decision Simulator — Especificación Completa para Guiar la Implementación

> **Cómo usar este documento:** Cada sección está redactada como una especificación accionable. Puedes copiar cualquier sección como prompt inicial en un chat nuevo con un LLM para generar el código correspondiente. Las decisiones están justificadas para que el LLM no cuestione lo ya resuelto. La sección 16 contiene el prompt de arranque sugerido.

---

## 0. Visión y Objetivos

**Producto:** Simulador interactivo que permite a cualquier persona experimentar un día completo de trabajo como taxista en NYC, comparando sus decisiones contra la política óptima (XGBoost) y contra el baseline (aceptar todo).

**Objetivo profesional:** Demostrar capacidad de aplicar Data Science a problemas reales, con énfasis en la integración de modelos predictivos, simulación secuencial, y una arquitectura de producto que escala. Es una carta de presentación, no un SaaS comercial.

**Éxito =** App funcional que se hace viral y abre oportunidades laborales. Sin deadline.

**Anti-scope:** Sin login, sin app móvil nativa (la web sí debe ser usable en móvil), sin i18n (idioma único: inglés), sin colaboración en tiempo real, sin descarga de datos crudos por el usuario, sin métricas públicas de uso, sin publicar datasets procesados, sin `CONTRIBUTING.md` (no se aceptan contribuciones externas).

---

## 1. Arquitectura General [v2.1]

**Regla de red (no negociable):** la API plumber2 **solo es accesible desde la red privada de Docker** y sus únicos clientes son la **app Shiny** y el servicio público **`share`**. La API no publica ningún puerto en el host, no tiene ruta en Nginx, no está detrás de Cloudflare y no tiene endpoints públicos. Todo lo que debe verse desde Internet (páginas y PNG para compartir, lista de espera) lo sirve `share`, un servicio mínimo **sin credenciales de Postgres** que obtiene los datos de la API por la red privada. Si `share` cae, el juego sigue funcionando; solo fallan compartir y la lista de espera.

```
Internet
   │
   ▼
[Cloudflare CDN] ─── DNS + proxy + TLS edge + caché de /share/*.png
   │
   ▼
[Nginx en VM ARM] ─── TLS Let's Encrypt + rate limit + intercepta 503
   │
   ├─ /          → [ShinyProxy :8080] → Contenedor Shiny efímero (max 10, techo 12)
   ├─ /share/*   → [share :8001]  (HTML con Open Graph + CTA, y PNG)
   ├─ /waitlist  → [share :8001]  (POST)
   └─ /api/*     → 404            (la API no tiene ruta pública)

Quién puede llamar a la API (solo por la red privada):
  shiny-app ──httr2 + X-Internal-Key + X-Client-IP + X-Resume-Code──► api ──pool──► postgres (named volume)
  share     ──httr2 + X-Internal-Key + X-Client-IP─────────────────► api   └─redux─► redis
  share ──redux──► redis (caché de PNG y contadores de vistas; sin acceso a Postgres)

Volúmenes de solo lectura con datos del release (descargados una vez en el deploy):
  /srv/nyctaxi/models → api        /srv/nyctaxi/data → shiny-app

Cron del host ──► pg_dump ──► /backups/ (disco local, retención 4 semanas)
Cron del host ──► disk_check.sh ──► correo si disco > 80 %
```

### 1.0 Redes Docker y exposición [v2.1]

|Red|Miembros|Propósito|
|---|---|---|
|`nyctaxi_edge_net`|nginx, shinyproxy, share|Tráfico entrante desde Nginx|
|`nyctaxi_api_net`|shinyproxy, shiny-app (×N), share, api|**Única vía de acceso a la API**|
|`nyctaxi_data_net`|api, share, postgres, redis|Datos. Los contenedores Shiny **no** están aquí|

- **Puertos publicados en el host:** solo nginx (80 y 443). Ningún otro servicio usa `ports:`; el resto usa `expose:`.
- **Postgres** solo vive en `nyctaxi_data_net` y la API es la única con sus credenciales. Los contenedores Shiny no pueden alcanzar Postgres ni Redis.
- **`share`** está en `data_net` solo para usar Redis; no recibe `POSTGRES_*`.
- **ShinyProxy** se une a `nyctaxi_api_net` porque `internal-networking` lo exige; no recibe `API_INTERNAL_KEY`.
- **Defensa en capas:** aunque alguien alcanzara la red, la API exige `X-Internal-Key` (y `X-Resume-Code` para experimentos).
- Se verifica con pruebas automáticas de exposición (ver 10).

### 1.1 Servicios Docker y recursos asignados [v2]

|Servicio|Imagen|RAM (límite)|CPU (tope)|Puerto interno|
|---|---|---|---|---|
|nginx|`nginx:alpine`|128 MB|0.25|80, 443|
|shinyproxy|`openanalytics/shinyproxy:3.2.4`|512 MB|0.5|8080|
|api|`ghcr.io/angelfelizr/nyc-taxi-api:latest`|**1.5 GB**|1.0|8000 (solo red privada)|
|share **[v2.1]**|`ghcr.io/angelfelizr/nyc-taxi-share:latest`|256 MB|0.25|8001 (solo desde Nginx)|
|postgres|`postgres:16-alpine`|**1 GB** (`shared_buffers=256MB`)|0.5|5432 (solo red privada)|
|redis|`redis:7-alpine`|256 MB|0.25|6379 (solo red privada)|
|shiny-app (efímero × **10**, techo 12)|`ghcr.io/angelfelizr/nyc-taxi-shiny:latest`|512 MB c/u|0.5 c/u|3838|

**Restricción total:** VM ARM Oracle Cloud (2 OCPU / 12 GB RAM).

**Presupuesto de memoria [v2]:** servicios fijos ≈ 3.6 GB (incluye `share`); con 10 instancias Shiny ≈ 8.7 GB, dejando ~3.3 GB de holgura para SO, caché de página y picos. Subir a 12 instancias solo si el load test (Fase 8) confirma holgura ≥ 2 GB y latencia aceptable. Se añade **swap de 2 GB** como red de seguridad. Los límites de CPU son topes, no reservas: la suma (≈ 8 CPU) sobrecompromete los 2 OCPU a propósito, y el load test mide la latencia p95 de `/sensitivity` bajo carga para validarlo.

**Criterio de la Fase 1 [v2]:** medir el RSS real de la API con los modelos cargados y `mori`; si supera 1.2 GB, subir el límite o descargar `DecisionTree` a demanda.

**Dominio:** `nyctaxiapp.angelfeliz.com` (Let's Encrypt). Cloudflare al frente.

### 1.2 Naturaleza del Repositorio: Monorepo

**Decisión:** Un único repositorio Git público (`github.com/AngelFelizR/NycTaxiApp`) contiene los **cuatro artefactos desplegables** que conforman el sistema:

1. **API plumber2** (`api/`) → imagen Docker `ghcr.io/angelfelizr/nyc-taxi-api:latest`. **Solo red privada**; la consumen únicamente la app Shiny y `share`.
2. **App Shiny** (`app/`) → imagen Docker `ghcr.io/angelfelizr/nyc-taxi-shiny:latest`
3. **Servicio público `share`** (`share/`) → imagen Docker `ghcr.io/angelfelizr/nyc-taxi-share:latest`. Sirve las páginas y PNG de compartir y la lista de espera; no tiene acceso a Postgres. **[v2.1]**
4. **Infraestructura** (`infra/`) → configuración de Nginx, ShinyProxy, Postgres, Redis, scripts de backup

**Justificación:**

- **Contrato compartido.** `contract/openapi.yaml` es la fuente de verdad que la API implementa y la app consume. Tenerlos en repos separados invita a desincronización.
- **Cambios atómicos.** Un PR que añade un endpoint a la API y el consumo correspondiente en la app es un solo cambio revisable.
- **CI/CD unificado.** Un solo workflow de GitHub Actions construye las tres imágenes, corre todos los test suites, y despliega en un solo paso.
- **Versionado coherente.** El tag `v1.2.0` del repo implica API v1.2.0 y app v1.2.0. `experiments.app_version` y `experiments.model_version` rastrean qué combinación sirvió cada experimento.
- **Portafolio.** Un monorepo bien organizado demuestra capacidad de gestionar sistemas distribuidos, no solo scripts aislados.

**Reglas del monorepo:**

1. **Un solo `.env` en la raíz.** Variables compartidas (`POSTGRES_*`, `REDIS_*`) y específicas (`TAXI_API_URL` la usan la app y `share`; `API_INTERNAL_KEY` la usan la app, `share` y la API; `MODEL_VERSION`, `IP_HASH_SALT` solo la API).
2. **Un solo `docker-compose.yml` en la raíz.** Cada servicio apunta a su Dockerfile.
3. **Un solo `default.nix` raíz** que importa los submódulos (`nix/r-api.nix`, `nix/r-shiny.nix`).
4. **CI/CD unificado** en `.github/workflows/`. Jobs: `build-api`, `build-shiny`, `build-share`, `test-contract`, `test-api`, `test-shiny`, `test-share`, `deploy`.
5. **Semver único para el repo.** `CHANGELOG.md` en la raíz. Los tags son del repo completo.
6. **Path-based triggers.** GitHub Actions usa `paths:` para decidir qué construir:
    - Cambios en `api/**` → reconstruir `nyc-taxi-api`.
    - Cambios en `app/**` → reconstruir `nyc-taxi-shiny`.
    - Cambios en `share/**` → reconstruir `nyc-taxi-share`.
    - Cambios en `contract/**` o `infra/**` → reconstruir las tres imágenes.
7. **Sin submódulos Git.** Sin `git submodule`, sin repos anidados. Todo vive aquí.
8. **README raíz** describe el sistema completo, no un componente. Cada subcarpeta puede tener su propio README más técnico.
9. **ADRs viven en `docs/decisions/`** y aplican a todo el monorepo.
10. **Un solo `CHANGELOG.md`** en la raíz con formato [Keep a Changelog](https://keepachangelog.com/).

### 1.3 Estructura de primer nivel del monorepo

```
nyc-taxi/
├── README.md                    # Narrativa del sistema completo
├── CHANGELOG.md                 # Semver del monorepo
├── LICENSE
├── .env.example
├── .gitignore
├── docker-compose.yml           # Todos los servicios
├── docker-compose.prod.yml      # Overrides de producción
├── default.nix                  # Entorno raíz que importa nix/*
│
├── contract/                    # Fuente de verdad API
├── api/                         # API plumber2 → imagen propia
├── app/                         # App Shiny → imagen propia
├── share/                       # Servicio público de compartir (HTML/PNG/waitlist) → imagen propia   [v2.1]
├── infra/                       # Configs y scripts (no imagen propia)
├── tools/                       # Scripts offline (p. ej. distribución de referencia)   [v2]
├── nix/                         # Módulos de dependencias
├── docs/                        # Quarto website + ADRs + runbook
│   ├── investigation-phases/
│   ├── decisions/               # ADRs
│   └── operations/              # runbook.md
└── .github/workflows/           # CI/CD unificado
```

---

## 2. Decisiones de Persistencia

### 2.1 PostgreSQL local (no Supabase)

**Justificación:** Supabase Free Tier limita a 500 MB, 50K inserciones/mes y 0 días de retención de backups. Con 65K+ decisiones simuladas, se agotaría. PostgreSQL local elimina dependencias externas y da control total.

**Configuración:** Named volume `pgdata`. Solo la API expone la red privada. `restart: unless-stopped`.

### 2.2 Esquema de base de datos (4 tablas) [v2]

```sql
-- 001_init.sql

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Participantes (captación de leads, no autenticación)
CREATE TABLE participants (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email              TEXT UNIQUE,                -- opcional, en claro (necesario para enviar la tarjeta)
  name               TEXT,                       -- opcional, en claro
  marketing_consent  BOOLEAN NOT NULL DEFAULT FALSE,  -- [v2] checkbox separado, desmarcado por defecto
  ip_hash            TEXT NOT NULL,              -- [v2] SHA-256(IP_HASH_SALT || ip); nunca la IP en claro
  country            TEXT,                       -- [v2] de la cabecera CF-IPCountry
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Experimentos (un día simulado)
CREATE TABLE experiments (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id    UUID REFERENCES participants(id),
  resume_code_hash  TEXT NOT NULL UNIQUE,      -- SHA-256
  share_token       TEXT NOT NULL UNIQUE,      -- 12 chars base64url
  seed              BIGINT NOT NULL,
  seed_is_custom    BOOLEAN NOT NULL DEFAULT FALSE,   -- [v2] semilla editada por el usuario → resultado no oficial
  status            TEXT NOT NULL CHECK (status IN ('setup','in_progress','finished','abandoned')),
  -- Condiciones iniciales
  company           TEXT NOT NULL,
  start_datetime    TIMESTAMPTZ NOT NULL,
  start_location_id INTEGER NOT NULL,
  -- Resultados finales (NULL hasta terminar). Wage = (driver_pay + tips) / horas de jornada (ver ADR-025)
  final_user_wage       NUMERIC(10,2),
  final_policy_wage     NUMERIC(10,2),
  final_baseline_wage   NUMERIC(10,2),
  pct_following_policy  NUMERIC(5,2),
  outcome               TEXT CHECK (outcome IN
    ('beat_model','tied_model','beat_baseline','lost_to_baseline','no_rides')),  -- [v2] calculado en servidor
  user_percentile       NUMERIC(5,2),          -- [v2] percentil frente a la distribución de referencia
  -- Feedback
  feedback_rating   SMALLINT CHECK (feedback_rating BETWEEN 1 AND 5),
  feedback_comment  TEXT,
  feedback_public   BOOLEAN DEFAULT FALSE,
  -- Analytics de compartir (persistidos por job diario)
  share_views       INTEGER NOT NULL DEFAULT 0,
  -- Versiones
  model_version     TEXT NOT NULL,
  app_version       TEXT NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at       TIMESTAMPTZ
);

CREATE INDEX idx_experiments_participant ON experiments(participant_id);
CREATE INDEX idx_experiments_status ON experiments(status);
CREATE INDEX idx_experiments_share_token ON experiments(share_token);

-- Decisiones (todas las trayectorias: user, policy, baseline)
CREATE TABLE decisions (
  experiment_id     UUID NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
  decision_source   TEXT NOT NULL CHECK (decision_source IN ('user','policy','baseline')),
  step              INTEGER NOT NULL,
  trip_id           BIGINT NOT NULL,
  accepted          BOOLEAN NOT NULL,
  model_recommended BOOLEAN NOT NULL,          -- [v2] se calcula para las 3 fuentes (en 'policy' siempre = accepted)
  trip_miles        NUMERIC(8,2),
  trip_time         INTEGER,                   -- segundos
  driver_pay        NUMERIC(10,2),
  tips              NUMERIC(10,2),
  pu_location_id    INTEGER,
  do_location_id    INTEGER,
  request_datetime  TIMESTAMPTZ,
  dropoff_datetime  TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (experiment_id, decision_source, step)
);

CREATE INDEX idx_decisions_experiment ON decisions(experiment_id);
CREATE INDEX idx_decisions_source ON decisions(experiment_id, decision_source);

-- Lista de espera para cuando la app está llena (503)   [v2]
CREATE TABLE waitlist (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT NOT NULL UNIQUE,
  ip_hash     TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 2.3 Decisiones clave del esquema

- **No hay tabla `share_events`.** Los eventos de compartir se registran en logs estructurados y en contadores Redis.
- **No hay tabla `trips_snapshot`.** Todos los viajes (aceptados y rechazados) se guardan en `decisions` para las tres trayectorias.
- **`decisions` cubre los 3 caminos:** el usuario, la política, y el baseline. Se pre-calculan al crear el experimento con la misma semilla, y se revelan al usuario progresivamente.
- **Idempotencia:** `(experiment_id, decision_source, step)` como PK natural.
- **`updated_at` se actualiza manualmente.** No hay trigger. Cada endpoint que modifica un experimento incluye `SET updated_at = now()` explícitamente.
- **Retención [v2]:** experimentos y decisiones se conservan indefinidamente (volumen trivial y valor analítico). Los datos personales (`email`, `name`) **sí se eliminan a solicitud** mediante un procedimiento manual documentado en el runbook (ver 9.1). No hay endpoint `DELETE` público. No hay TTL ni archivado de experimentos.
- **`outcome` y `user_percentile` se calculan siempre en el servidor** al hacer `finish`, nunca en la UI, para que el PNG, el HTML compartido y la pantalla Results muestren exactamente el mismo veredicto.
- 

### 2.4 `resume_code`, `share_token` y autenticación de experimentos [v2]

- **`resume_code`:** generado con `openssl::rand_bytes(16)`, codificado en base64url (22 chars). Se guarda **hasheado con SHA-256** (sin salt, la entropía es alta). La API lo devuelve **una sola vez** en la respuesta de `POST /experiments`.
- **El `resume_code` es obligatorio** para cualquier endpoint bajo `/experiments/{id}/...` (cabecera `X-Resume-Code`, validada contra el hash; 403 si no coincide). El `experiment_id` (UUID) **ya no es una credencial** ni se considera secreto, pero tampoco se muestra en superficies públicas.
- **Dónde lo ve el usuario:** en un modal tras "Start The Day" (con botón copiar), en el botón discreto "My resume code" del sidebar de Trips y en el chip de Results. `www/js/resume.js` lo guarda además en localStorage y lo pasa a Shiny al cargar. El `?exp=<uuid>` en la URL solo identifica; el código autentica.
- **`share_token`:** 12 caracteres base64url (72 bits de entropía), suficiente para 100K shares sin colisiones. URL-safe, sin padding. Se guarda en claro porque se muestra en la URL. **No va firmado:** su entropía hace inviable la enumeración. Solo expone datos agregados, nunca PII ni `experiment_id`.
- **Un solo `share_token` por experimento.** Los query params `?ref=linkedin`, `?ref=x`, `?ref=copy` diferencian el canal de origen.
- **Autenticación servicio a servicio [v2.1]:** **todo** endpoint de la API exige `X-Internal-Key` (valor de `API_INTERNAL_KEY`), que solo conocen la app Shiny, `share` y la API. La API no tiene endpoints públicos.

### 2.5 Persistencia de decisiones

**Write-through después de cada decisión.** El endpoint `POST /decisions` es idempotente gracias a la PK natural. Si el usuario cierra el navegador a mitad del día, al reanudar se reconstruye el estado desde `decisions`. **No hay deshacer:** una decisión registrada es definitiva (un reintento con distinto payload devuelve 409).

**Reconstrucción de estado:** la API expone `GET /experiments/{id}/state` que devuelve las decisiones registradas + el próximo viaje a presentar (calculado on-the-fly desde la semilla).

---

## 3. Lógica de Simulación

La simulación se implementa en la API en R, portando `simulate_trips()` del paquete `NycTaxi` existente. Reglas fijas:

1. **Duración:** 8 horas + 30 min de break (después de 4h, tras terminar viaje en curso).
2. **Viajes:** no se pre-generan todos. Se generan on-the-fly según la ventana de búsqueda y el radio expandible (1→3→5→+2 millas cada 2 min).
3. **Semilla:** el usuario puede editarla (opción avanzada, con pop-up explicativo). Por defecto se genera aleatoria al crear el experimento. **[v2]** Si el usuario la edita, `seed_is_custom = TRUE`: la jornada se juega con normalidad, pero el resultado se marca **"Custom seed — unofficial"** en Results, en el PNG y en el HTML compartido, y **nunca** genera el texto de victoria (ver 6.6). Motivo: con la recomendación visible, probar semillas hasta ganar haría falso el "I beat the model".
4. **Dataset:** `NycTrips2024_sample_week.parquet` (188 MB) — una semana completa de 2024.
5. **Compañía:** debe permanecer constante en el día. Las 3 trayectorias comparten la compañía del setup.
6. **WAV:** si el taxi inicial es WAV, puede tomar viajes WAV y no-WAV. Si no, solo no-WAV.
7. **Los 3 caminos:**
    - **User:** decisiones del usuario (con recomendación del modelo visible).
    - **Policy:** siempre seguir la recomendación del modelo XGBoost.
    - **Baseline:** aceptar siempre el primer viaje encontrado.
    - Los 3 caminos comparten semilla y condición inicial, pero divergen por las decisiones. Se pre-calculan al crear el experimento y se guardan en `decisions`.
8. **Regla de rechazo total [v2]:** si el usuario rechaza todos los viajes, el reloj sigue avanzando según las reglas de expansión de búsqueda. No hay tope al número de rechazos. Al llegar al límite de 8h+30min, el experimento termina con wage = $0 y `outcome = no_rides`. Results muestra la comparación y un texto neutro y breve ("You rejected every ride, so your day ended at $0."), y el texto de compartir tiene su propia variante (6.6).
9. **Definición de wage [v2] :** `wage = (Σ driver_pay + Σ tips) / horas de jornada`, contando el tiempo ocioso y excluyendo el break de 30 min. Es la misma fórmula para las tres trayectorias. Se documenta en ADR-025.
10. **Cálculo de `outcome` [v2]:** se evalúa en `POST /finish` con esta precedencia:
    1. `accepted == 0` → `no_rides`
    2. `user_wage > policy_wage + 0.01` → `beat_model`
    3. `|user_wage − policy_wage| ≤ 0.01` → `tied_model`
    4. `user_wage > baseline_wage` → `beat_baseline`
    5. en otro caso → `lost_to_baseline`
11. **Color y presión al usuario [v2]:** durante Trips **no hay ningún indicador de color** de rendimiento comparado (ni semáforo, ni delta coloreado). Al terminar la jornada, en Results, la comparación final usa verde (mejor) y rojo (peor) **siempre acompañados de icono y texto** (▲ / ▼), para no depender solo del color. Esto resuelve la contradicción de la v1.
12. **Duración de la jornada de juego [v2]:** se estima 8–15 min por jornada. Se mide en la Fase 8 (objetivo: mediana ≤ 12 min). La reanudación hace que pausar sea seguro.

---

## 4. Modelos

### 4.1 Modelo de política (Accept/Reject)

- **Archivo:** `AcceptRejectPolicyFitted.qs2` (345 MB)
- **Tipo:** tidymodels workflow con XGBoost
- **Umbral:** P(high-value) > 0.90 (fijo, parte de la política, no configurable)
- **Carga:** en el proceso principal de la API, antes de levantar plumber2. Se usa `mori` para compartir en memoria entre daemons (zero-copy).
- **Endpoint:** `POST /predict` recibe un viaje + contexto y devuelve `{accepted: bool, probability: float}`.

### 4.2 Modelo de validación de inicio

- **Archivo:** `DecisionTreeWfFitted.qs2` (2.84 MB)
- **Tipo:** tidymodels workflow con árbol de decisión
- **Uso:** endpoint `POST /validate-trip-start` recibe `(company, datetime, location_id)` y devuelve `{is_optimal: bool, better_company, better_datetime}`.

### 4.3 Lookup de horas válidas

- **Archivo:** `ValidHoursToStartWorking.qs2` (301 bytes)
- **Uso:** `/recommend-start` es determinista. Dado un `(datetime, company)`, encuentra la próxima `(hour, week_day)` válida y la devuelve. No involucra al modelo.

### 4.4 Interpretabilidad limitada

**Decisión:** El usuario ve las variables crudas del viaje (PULocationID, DOLocationID, trip_miles, driver_pay, trip_time, request_datetime, hvfhs_license_num), pero **no ve la transformación de la receta** (harmónicas, joins geoespaciales, dummies, etc.). El modelo es interpretable a nivel de features de entrada, no a nivel de features transformados. Justificación: la transformación agresiva es parte del pipeline interno y no aporta a la UX. Si el usuario quiere profundidad, se remite al artículo Quarto.

### 4.5 Versionado y distribución de archivos [v2]

- Los modelos y datos viven en `github.com/AngelFelizR/NycTaxiApp/releases/tag/v0.0.1-data`. **No van en la imagen.**
- **El script de deploy los descarga una sola vez** a `/srv/nyctaxi/models` y `/srv/nyctaxi/data` (con verificación SHA-256) y se montan **solo lectura** en los contenedores. Así se evita descargar 345 MB en cada reinicio de la API y que cada contenedor Shiny dependa de GitHub en tiempo de ejecución. Si el deploy no puede verificar el checksum, aborta sin reiniciar servicios.
- `experiments.model_version` registra la versión usada. **No se re-entrena durante el experimento activo.** El modelo es fijo.
- Si en el futuro se actualizara el modelo mientras hay experimentos en curso, esos experimentos continuarían con el nuevo modelo (sin pineo). Aceptable: es una demostración, no un servicio crítico.

### 4.6 Distribución de referencia [v2]

- **Problema que resuelve:** una sola jornada con una semilla no distingue habilidad de suerte.
- **Archivo:** `ReferenceDistribution.qs2`, generado offline por `tools/build_reference_distribution.R`: simula la política y el baseline sobre ≥ 1,000 semillas y condiciones de inicio válidas, por compañía. Se publica en el release de datos.
- **Uso:** al terminar, la API calcula `user_percentile` (percentil del wage del usuario dentro de la distribución de la política para su compañía). Results lo muestra como una línea de texto bajo las curvas ("Your day ranked at the Nth percentile of 1,000 simulated model days"), más una nota breve de que un día es una sola muestra. **No es un KPI adicional**, para respetar el máximo de 6.

---

## 5. API (plumber2)

### 5.1 Estructura de archivos

```
api/
├── plumber.R                    # entrypoint
├── R/
│   ├── endpoints/               # 1 archivo por endpoint
│   ├── middleware/
│   │   ├── internal_auth.R      # [v2] X-Internal-Key + X-Resume-Code
│   │   ├── client_ip.R          # [v2] resuelve y hashea la IP real
│   │   ├── rate_limit.R         # Redis, 3 exp/día/IP
│   │   ├── error_handler.R
│   │   └── cors.R
│   ├── db/
│   │   ├── pool.R
│   │   ├── migrations.R
│   │   └── queries.R
│   ├── ml/
│   │   ├── load_model.R         # carga en proceso principal
│   │   ├── predict.R
│   │   ├── recommend.R
│   │   ├── outcome.R            # [v2] outcome + percentil
│   │   └── sensitivity.R
│   ├── (el render de HTML/PNG vive en el servicio share/, ver 5.10)
│   ├── cache/redis.R
│   └── utils.R
├── migrations/
│   └── 001_init.sql
└── tests/testthat/
```

### 5.2 Catálogo de endpoints de la API (18, todos internos) [v2.1]

Acceso: **I** = requiere `X-Internal-Key`; **R** = además requiere `X-Resume-Code`. **Ningún endpoint de la API es público:** solo la app Shiny y el servicio `share`, desde la red privada, pueden llamarla.

|Método|Ruta|Descripción|Acceso|Rate limit|
|---|---|---|---|---|
|GET|`/health`|Estado de pool + modelos (healthcheck de Docker)|I|No|
|POST|`/predict`|Inferencia accept/reject|I|Global|
|POST|`/recommend-start`|Próxima hora válida|I|Global|
|POST|`/validate-trip-start`|¿Es óptimo el inicio?|I|Global|
|POST|`/sensitivity`|Dataframes para ggiraph (zonas)|I+R|Por experimento|
|GET|`/trips/sample`|Muestra de viajes (con semilla)|I|Global|
|GET|`/zones/geojson`|GeoJSON de zonas|I|No|
|POST|`/experiments`|Crear experimento (3 trayectorias); devuelve `resume_code` una vez|I|**3/día/IP real**|
|GET|`/experiments/{id}`|Reanudar estado|I+R|No|
|GET|`/experiments/{id}/state`|Estado + próximo viaje|I+R|No|
|POST|`/experiments/{id}/decisions`|Registrar decisión (idempotente)|I+R|No|
|POST|`/experiments/{id}/finish`|Terminar y calcular resultados, `outcome`, percentil|I+R|No|
|POST|`/experiments/{id}/feedback`|Guardar rating/comment|I+R|No|
|POST|`/experiments/{id}/abandon`|Marcar abandonado|I+R|No|
|POST|`/experiments/{id}/share-email`|Enviar resultados por email (máx. 3 por experimento)|I+R|Por IP|
|GET|`/share-data/{token}`|Datos agregados del resultado para `share` (sin PII ni `experiment_id`; 404 si no está `finished`)|I|No|
|POST|`/waitlist`|Guardar email de la lista de espera (lo llama `share`)|I|5/día/IP real|
|GET|`/metrics`|Métricas JSON (ad-hoc)|I|No|

**Rutas públicas (las sirve el servicio `share`, 3):**

|Método|Ruta|Descripción|Límite|
|---|---|---|---|
|GET|`/share/{token}`|HTML con Open Graph y CTA|Nginx 10r/s|
|GET|`/share/{token}.png`|PNG 1200×630 (solo si `finished`)|Nginx 10r/s + caché|
|POST|`/waitlist`|Valida el email y lo reenvía a la API|Nginx + 5/día/IP (lo aplica la API)|

Nginx solo enruta `/` (ShinyProxy), `/share/*` y `/waitlist` (servicio `share`). Cualquier `/api/*` responde 404.

### 5.3 Códigos de error estandarizados

- **400** validación fallida (payload inválido)
- **403** `X-Internal-Key` o `X-Resume-Code` inválido o ausente [v2]
- **404** recurso no existe
- **409** conflicto (doble decisión con distinto payload)
- **422** payload semánticamente inválido
- **429** rate limit excedido (con `Retry-After` header)
- **500** error interno
- **503** modelo no cargado, Postgres no disponible, o SMTP falló

(Se elimina el 410: nada expira.) **[v2]** Todos los mensajes de error visibles al usuario están en inglés, p. ej. `"You've reached the limit of 3 experiments per day."`.

### 5.4 Resolución de IP y rate limit [v2]

**Problema de la v1:** la app Shiny llama a la API desde el servidor, por la red privada, así que la API nunca veía `CF-Connecting-IP`. El contador habría sido global o por contenedor.

**Decisión:**

1. Nginx fija `X-Client-IP $http_cf_connecting_ip` al enrutar hacia ShinyProxy y hacia `share`.
2. La app Shiny (leyéndola de `session$request`) y el servicio `share` reenvían esa IP a la API en **cada** llamada como `X-Client-IP`, junto con `X-Internal-Key`.
3. La API **solo acepta `X-Client-IP` junto con una `X-Internal-Key` válida**; sin la clave responde 403. No existe ruta alternativa: al no recibir nunca tráfico directo de Internet, no hay un caso en que deba leer `CF-Connecting-IP` por su cuenta.
4. Todo uso posterior es sobre el hash: `ip_hash = sha256(IP_HASH_SALT || ip)`. Ni Redis ni Postgres ni los logs guardan la IP en claro.
5. **Verificación obligatoria en la Fase 4:** confirmar con un test que ShinyProxy entrega la cabecera al contenedor. **Plan B** si no la entrega: un endpoint del servicio `share` (`GET /share/client-token`) devuelve un token HMAC con la IP y una marca de tiempo; el navegador lo pasa a Shiny con `Shiny.setInputValue`, y Shiny lo reenvía como `X-Client-IP-Token` para que la API lo verifique (no falsificable). Se registra en ADR-016.

```r
client_ip_hash <- function(req) {
  # internal_auth.R ya validó X-Internal-Key (403 si falta). La IP real llega
  # reenviada por shiny-app o share en X-Client-IP.
  ip <- req$HTTP_X_CLIENT_IP %||% "unknown"
  digest::digest(paste0(Sys.getenv("IP_HASH_SALT"), trimws(ip)),
                 algo = "sha256", serialize = FALSE)
}

rate_limit_middleware <- function(req, res) {
  # Solo aplica a POST /experiments
  if (req$REQUEST_METHOD != "POST" || !grepl("/experiments$", req$PATH_INFO)) {
    return(plumber2::Next)
  }
  clave <- paste0("exp:ip:", client_ip_hash(req), ":", format(Sys.Date(), "%Y%m%d"))
  contador <- redis$INCR(clave)
  if (contador == 1) redis$EXPIRE(clave, 86400)
  if (contador > 3) {
    res$status <- 429
    res$setHeader("Retry-After", seconds_until_midnight_utc())
    res$body <- jsonlite::toJSON(list(
      error = "rate_limit_exceeded",
      message = "You've reached the limit of 3 experiments per day."
    ))
    return(plumber2::Break)
  }
  plumber2::Next
}
```

**Headers de rate limit en respuesta:** `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`. Se loggean, **no se muestran en UI**.

### 5.5 Endpoint `/sensitivity`

**Request:**

```json
POST /sensitivity
{
  "experiment_id": "uuid",
  "trip_id": 1234,
  "pickup_id": null,
  "dropoff_id": null,
  "grid_size": 50
}
```

**Response:** (tráfico interno entre Shiny y la API; no pasa por Nginx)

```json
{
  "recommendation": "accept",
  "pickup_suggested": 132,
  "dropoff_suggested": 144,
  "meta": {
    "threshold": 0.9,
    "original_label": "PU (129) Queens - Jackson Heights / DO (205) Queens - Saint Albans",
    "pu_label": "(132) Queens - JFK Airport",
    "do_label": "(144) Manhattan - Little Italy/NoLiTa",
    "subtitle_html": "<b>Original:</b>...",
    "original_point": {"trip_time_sec": 2400, "driver_pay": 33.5}
  },
  "grid_original": [{"trip_time_sec": 0, "driver_pay": 0, "prob": 0.12}, ...],
  "grid_pu": [...],
  "grid_do": [...]
}
```

**Implementación:**

- Reutiliza `select_zone_with_high_change()` y `plot_decision_boundary()` del proyecto existente, **pero desacoplando el cálculo del plotting**.
- `plot_decision_boundary` se divide en dos: `compute_decision_grid()` (devuelve dataframes) y `plot_sensitivity_girafe()` (en la UI).
- Caché Redis: clave `sens:{experiment_id}:{trip_id}:{pu_id}:{do_id}`, TTL 1 hora.
- Grid reducido a 30×30 si `X-Device: mobile` en headers (la app lo fija a partir del ancho de pantalla).
- 7,500 predicciones por llamada en frío (~2s), ~50ms con caché.

### 5.6 Endpoint `/share-email`

**Decisión:** `POST /experiments/{id}/share-email` recibe `{email: "..."}` (si no lo dio en Setup) o nada (si ya lo dio). Implementación sincrónica simple con `curl` a un servicio SMTP; sin colas. La promesa de "recibirás tu tarjeta por correo" es real, no marketing. Requiere `SMTP_URL` en `.env`. El PNG adjunto se pide al servicio `share` por la red privada (`http://share:8001/share/{token}.png`). **[v2]** Máximo 3 envíos por experimento y límite por IP, para evitar que se use como relé de spam.

**Manejo de errores SMTP:** Si SMTP falla, devuelve 503 con mensaje "We couldn't send the email, please try again later". El error se loggea con stacktrace. No hay reintentos automáticos; el usuario decide si reintentar.

**Entregabilidad [v2]:** el dominio remitente debe tener SPF, DKIM y DMARC configurados (en Cloudflare DNS) antes de la Fase 6; si no, los correos caerán en spam y la promesa será falsa en la práctica.

### 5.7 CORS [v2]

Como la API es solo de red privada y el navegador nunca la llama (solo Shiny y `share`, de servidor a servidor), **CORS es una defensa en profundidad, no un requisito**. Solo `https://nyctaxiapp.angelfeliz.com` en producción; `http://localhost:3838` en desarrollo (variable `ENV`). Se bloquea `Origin: null`.

### 5.8 Versionado de API

Se versiona globalmente mediante tags del monorepo. **No hay prefijo `/v1/`** en las rutas porque la API solo será consumida por la app del mismo repo. Los breaking changes se coordinan en un solo PR.

### 5.9 Carga de modelos

```r
# plumber.R — ANTES de api()
library(qs2)
library(mori)
model_policy <- qs_read("/models/AcceptRejectPolicyFitted.qs2")   # volumen de solo lectura
model_start <- qs_read("/models/DecisionTreeWfFitted.qs2")
valid_hours <- qs_read("/models/ValidHoursToStartWorking.qs2")
# mori: compartir en memoria entre daemons
shared_policy <- mori::share(model_policy)
```

**Los modelos se cargan en el proceso principal antes de levantar plumber2.** El primer request no paga el costo de carga.

### 5.10 Servicio público `share` [v2.1]

Existe para que la API pueda ser 100 % privada: las páginas de compartir deben ser públicas (LinkedIn y X leen el `<head>` sin autenticarse), así que las sirve un servicio aparte, mínimo y sin acceso a la base de datos.

```
share/
├── plumber.R
├── R/
│   ├── api_client.R     # httr2 → API privada (X-Internal-Key + X-Client-IP)
│   ├── render_html.R    # Open Graph + CTA
│   ├── render_png.R     # ragg + patchwork
│   ├── cache.R          # Redis: bytes del PNG y contadores de vistas
│   └── bots.R           # filtro de User-Agent
└── tests/testthat/
```

**Rutas:** `GET /share/{token}`, `GET /share/{token}.png`, `POST /waitlist`, `GET /health` (solo healthcheck interno) y, solo si se activa el Plan B de IP (5.4), `GET /share/client-token`.

**Reglas:**

- **Sin Postgres.** No recibe credenciales de BD. Obtiene los datos con `GET /share-data/{token}` de la API (agregados, sin PII ni `experiment_id`; 404 si el experimento no está `finished`).
- **Reenvío de IP.** Pasa a la API `X-Client-IP` (de `CF-Connecting-IP` fijada por Nginx) y `X-Internal-Key`.
- **Lista de espera.** Valida el email y lo reenvía a `POST /waitlist` de la API, que aplica el límite de 5/día/IP.
- **Caché y contadores.** Guarda los bytes del PNG (TTL 24 h) y los contadores `share:views:{token}` en Redis. Un job diario **de la API** (la única con acceso a Postgres) persiste los contadores en `experiments.share_views`.
- **Dependencia inversa.** `share-email` de la API pide el PNG a `share` por la red privada; si `share` no responde, devuelve 503.
- **Aislamiento de fallos.** Si `share` cae, la simulación no se ve afectada.
- **Recursos:** 256 MB / 0.25 CPU.

---

## 6. UI Shiny

### 6.1 Principios rectores

1. **CERO `renderUI` para estructura.** Solo `renderText`, `renderPlot`, `renderGirafe`, `renderLeaflet` para contenido. `update*` para valores. `shinyjs::show/hide/toggle` para visibilidad.
2. **Excepción:** `modalDialog` con `uiOutput` interno (transitorio, justificado).
3. **Pre-carga total [v2]:** todos los datos estáticos (zonas, empresas, strings) se leen al arrancar desde el volumen de solo lectura `/srv/nyctaxi/data` (descargado y verificado una vez en el deploy; ver 4.5). La app no espera red para pintar ni depende de GitHub en tiempo de ejecución. Los datos no van en la imagen Docker.
4. **Bytecode precompilado:** `compiler::enableJIT(3)` en el Dockerfile.
5. **`allow-container-re-use: true`** en ShinyProxy. **[v2]** Como un contenedor puede servir a otro usuario después, el estado de sesión vive solo en `reactiveValues` (nunca en variables globales) y hay un test que lo verifica.
6. **Mobile-first en lo que importa [v2]:** el flujo de juego y las páginas compartidas deben funcionar en un viewport de 390 px (LinkedIn y X abren los enlaces sobre todo en móvil). Botones Accept/Reject de al menos 44 px de alto en pantallas táctiles.

### 6.2 Estructura de archivos

```
app/
├── app.R
├── R/
│   ├── theme.R
│   ├── constants.R               # precarga desde /srv/nyctaxi/data
│   ├── strings.R                 # [v2] todos los textos de cara al usuario, en inglés
│   ├── api_client.R              # [v2] añade X-Internal-Key, X-Client-IP, X-Resume-Code
│   ├── state.R
│   ├── charts/                   # theme_taxi, plot_wage_curve, plot_sensitivity
│   ├── maps/                     # leaflet_base, leaflet_trip
│   └── modules/
│       ├── mod_header.R
│       ├── mod_setup.R
│       ├── mod_confirm_modal.R   # único uso de uiOutput justificado
│       ├── mod_trips.R
│       ├── mod_trip_card.R
│       ├── mod_sensitivity.R
│       ├── mod_results.R
│       ├── mod_share.R
│       └── mod_feedback.R
├── www/
│   ├── fonts/                    # Inter + JetBrains Mono woff2
│   ├── css/custom.css
│   └── js/resume.js
└── data/                         # vacío; los datos llegan por volumen en runtime
```

### 6.3 Estructura de `app.R`

```r
ui <- page_navbar(
  id = "nav_principal",
  theme = theme_taxi(),
  title = tagList(tags$img(src = "logo.svg", height = "28px"),
                  "NYC Taxi Decision Simulator"),
  fillable = FALSE,
  header = mod_header_ui("header"),
  nav_panel("Setup",   value = "setup",   mod_setup_ui("setup")),
  nav_panel("Trips",   value = "trips",   mod_trips_ui("trips")),
  nav_panel("Results", value = "results", mod_results_ui("results")),
  nav_spacer(),
  nav_item(input_dark_mode(id = "modo", default = "auto"))
)

server <- function(input, output, session) {
  useShinyjs()
  estado <- init_estado(session)   # captura X-Client-IP de session$request
  mod_header_server("header", estado)
  mod_setup_server("setup", estado)
  mod_trips_server("trips", estado)
  mod_results_server("results", estado)
  mod_confirm_modal_server("confirm", estado)
  mod_share_server("share", estado)
  mod_feedback_server("feedback", estado)
}
```

### 6.4 Tema y paleta

```r
# theme.R
theme_taxi <- function(modo = c("light", "dark")) {
  modo <- match.arg(modo)
  bs_theme(
    version = 5,
    bg = if (modo == "light") "#ffffff" else "#16171d",
    fg = if (modo == "light") "#1f2328" else "#e6e6ea",
    primary = if (modo == "light") "#6d5dfc" else "#8b7dff",
    base_font = font_google("Inter", local = TRUE),
    code_font = font_google("JetBrains Mono", local = TRUE),
    "border-radius" = "0.5rem",
    "enable-shadows" = "false"
  ) |> bs_add_rules("...")
}
```

**Paleta por modo:**

|Token|Claro|Oscuro|
|---|---|---|
|Superficie|`#f6f7f9`|`#1e2028`|
|Borde|`#e3e6ea`|`#2c2f3a`|
|Success (accept)|`#d1f4dd` / `#0a5c2b`|`#1e4d2b` / `#6ee7a0`|
|Danger (reject)|`#fde2e4` / `#8b1a1a`|`#4a1a1a` / `#f8a5a5`|
|PU zone (sensitivity)|`lightslateblue` `#8470ff`|`#a99aff`|
|DO zone (sensitivity)|`#C44E52`|`#e07074`|
|Punto original|`#E6B800`|`#FFD700`|

**Contraste AA verificado:** `#6d5dfc` sobre `#ffffff` (ratio 6.8:1). Cumple AA.

### 6.5 Módulos — detalles clave

#### `mod_setup`

- Selectize de compañía, datetime, zona (con `selectizeInput` para búsqueda).
- Leaflet clickeable **bidireccional**: `observeEvent(input$map_click)` actualiza selectize; `observeEvent(input$location)` actualiza mapa con `leafletProxy`.
- Botón "Validate" → llama `/validate-trip-start`, muestra/oculta hints con `shinyjs`.
- Botón "Start The Day" → `POST /experiments`, guarda `experiment_id` en URL con `updateQueryString`, **[v2]** muestra el `resume_code` en un modal con botón copiar y navega a Trips.
- **Opción avanzada** (colapsada): editar semilla, con pop-up que explica que cambiar la semilla cambia los resultados de la simulación y **que el resultado quedará marcado como no oficial** **[v2]**.
- **Campo visible "Have a code?"** para reanudar o iniciar nuevo. Siempre visible, no solo localStorage.
- **Email opcional [v2]:** dos casillas separadas y desmarcadas por defecto: "Send me my result card" y "I agree to be contacted about Data Science services". Enlace al aviso de privacidad.

#### `mod_confirm_modal`

- **Modal obligatorio** tras validar las condiciones. El usuario no puede ir directo a Trips sin pasar por él.
- Único uso justificado de `uiOutput` (transitorio).

#### `mod_trips`

- `layout_columns(col_widths = c(3, 9), breakpoints = breakpoints(md = c(12, 12), lg = c(3, 9)))`.
- Sidebar: KPIs actualizados por `updateTextInput` sobre `textOutput`; botón discreto "My resume code".
- Gráficos acumulados (3 curvas: user/policy/baseline) con `renderGirafe`. **Sin color comparativo ni semáforo durante el juego** (ver 3.11).
- `mod_trip_card` con `leafletProxy` para rutas. Botones Accept/Reject de 44 px mínimo.
- `mod_sensitivity` con `updateSelectizeInput(server = TRUE)` para 250+ zonas.

#### `mod_results` [v2]

- **Máximo 6 KPIs** en `layout_columns`: Total Earnings, Hourly Wage, vs Policy, Trips Accepted, Trips Rejected, % Following Policy.
- 3 curvas acumuladas con `ggiraph`. La comparación final usa verde/rojo **con icono y texto** (▲/▼).
- Línea de texto con el percentil frente a la distribución de referencia y nota de "un día es una sola muestra" (4.6).
- Insignia **"Custom seed — unofficial"** si `seed_is_custom`.
- Botones: Descargar PNG, Copiar enlace, Compartir en X, Compartir en LinkedIn.
- Modal de feedback con rating 1-5 + comentario + checkbox público.
- Segundo prompt de email si no lo dio en Setup.
- Mostrar siempre la diferencia en una unidad interpretable: `+$4.82/hr vs policy`
- Cuando corresponda, mostrar también el porcentaje: `+$4.82/hr (+7.4%)`
- El valor debe representar la diferencia del **Hourly Wage** del usuario respecto a la política XGBoost bajo las mismas condiciones de simulación.
- El `experiment_id` no debe presentarse como un KPI ni como un elemento principal del resultado. Debe permanecer disponible dentro de una sección secundaria de **Technical details**, junto con la información necesaria para reproducir o identificar la simulación.
	- En la pantalla de Results puede mostrarse de forma discreta como:
		**Technical details ▸**  
		Experiment ID: `XXXXXXXX
	- El identificador debe seguir siendo accesible para debugging, reproducibilidad y soporte, pero no competir visualmente con el resultado principal de la experiencia.`
#### Reanudación [v2]

- El `experiment_id` se guarda en la URL (`?exp=<uuid>`) y `www/js/resume.js` guarda el `resume_code` en localStorage.
- Al cargar la app, si hay `?exp=` y un código válido (de localStorage o escrito en "Have a code?"), salta directo a Trips o Results según el estado. Sin código válido, pide el código.
- Si el usuario cierra antes de Results, al volver reanuda y eventualmente ve sus resultados.

#### Onboarding

- Pop-ups progresivos tipo Subway Surfers con `cicerone`. Solo la primera visita por navegador (localStorage).

#### Atajos de teclado [v2]

- **Flecha derecha** → preselecciona Accept. **Flecha izquierda** → preselecciona Reject. **Enter** → confirma la opción preseleccionada. Se evita así registrar una decisión irreversible por una pulsación accidental. Un clic o toque directo en el botón confirma de inmediato.
- **`?`** → modal de ayuda.
- **Escape** → cerrar modal (y quitar la preselección).
- Solo activos en la pantalla de Trips y solo en dispositivos con teclado (en táctiles se ocultan las pistas). Documentados en el footer con ícono de teclado clickeable.

#### Pending Time

- **Barra de progreso horizontal** con el número "X horas" centrado dentro de la barra. La barra decrece a medida que avanza el día.
- Colores: verde si queda >4h, amarillo si queda 2-4h, rojo si queda <2h. (Es un indicador de tiempo, no de rendimiento comparado.)

#### Cambio de tile layer en Leaflet

- El cambio claro/oscuro usa `leafletProxy() |> addProviderTiles(...)` para cambiar el tile layer **sin recargar el widget**. Se preserva el zoom, centro, y los markers.
- Dos providers: `CartoDB.Positron` (claro) y `CartoDB.DarkMatter` (oscuro).

### 6.6 Texto por defecto del post de X/LinkedIn [v2]

El texto depende de `outcome` (calculado en el servidor) y de `seed_is_custom`. Si `seed_is_custom = TRUE` se usa siempre el texto neutro, sea cual sea el resultado.

| `outcome`             | Texto                                                                                                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `beat_model`          | `I beat the model today. 🚕📊`<br>*You earned more per hour than the XGBoost policy in this simulated shift.*<br>*One simulated day is one sample. See how your result ranks across 1,000 model simulations.* |
| `tied_model`          | `I just matched the XGBoost policy over a simulated 8-hour NYC taxi shift. Can you beat it? 🚕📊`                                                                                                             |
| `beat_baseline`       | `I just simulated a full day as an NYC taxi driver. I couldn't beat the model, but I beat the baseline. Can you? 🚕📊`                                                                                        |
| `lost_to_baseline`    | `I simulated 8 hours as an NYC taxi driver and did worse than simply accepting every ride. Harder than it looks. 📉🚕`                                                                                        |
| `no_rides`            | `I simulated an NYC taxi shift by rejecting every ride. Earnings: $0. Can you do better? 🚕`                                                                                                                  |
| Semilla personalizada | `I just simulated a full day as an NYC taxi driver and compared myself to an XGBoost model. Try it yourself 🚕📊`                                                                                             |

El texto lo puede editar el usuario antes de publicar. LinkedIn no pre-rellena texto; solo X lo hace.

---

## 7. Compartir y Open Graph

### 7.1 Contenido y caché del PNG [v2]

- Generado en el servicio `share` con `patchwork` + `ragg::agg_png()`, 1200×630 px.
- 3 curvas acumuladas (user/policy/baseline) + etiqueta grande según `outcome`:

|`outcome`|Etiqueta|
|---|---|
|`beat_model`|"I beat the Model!"|
|`tied_model`|"I matched the Model"|
|`beat_baseline`|"I beat the Baseline!"|
|`lost_to_baseline`|"The Model won"|
|`no_rides`|"No rides, no pay"|
|`seed_is_custom`|Etiqueta neutra + "Custom seed — unofficial"|

- **Sin información personal y sin `experiment_id`.** Se identifica con "Day #" + los 6 primeros caracteres del `share_token` (ya público).
- **Solo se renderiza si el experimento está `finished`**; si no, 404.
- **Caché en tres niveles:** (1) la respuesta lleva `Cache-Control: public, max-age=86400, s-maxage=604800`; (2) regla de caché en Cloudflare para `/share/*.png`; (3) bytes del PNG en Redis, TTL 24 h. **No se guarda en disco.** El resultado es inmutable una vez terminado, así que cachear es seguro. Esto evita que los rastreadores de LinkedIn/X y un pico viral saturen el servicio `share` (y, a través de él, la API).

### 7.2 HTML con Open Graph y puerta de entrada [v2]

`GET /share/{token}` devuelve HTML estático con meta tags inyectadas server-side. **Nunca JavaScript.** LinkedIn/X leen el `<head>` estático.

**Cuerpo visible (nuevo):** la página no es solo para rastreadores; es la puerta de entrada de los visitantes. Contiene el PNG del resultado, una frase de contexto de una línea, y un **botón/enlace "Play your own day"** que apunta a `https://nyctaxiapp.angelfeliz.com/?ref=share`. Es un enlace HTML normal (sin JS ni redirección automática, que confundiría a los rastreadores). Diseño responsive, legible en 390 px.

Meta tags:

```html
<meta property="og:title" content="NYC Taxi Decision Simulator - Day #abc123">
<meta property="og:description" content="...">
<meta property="og:image" content="https://nyctaxiapp.angelfeliz.com/share/{token}.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="https://nyctaxiapp.angelfeliz.com/share/{token}">
<meta name="twitter:card" content="summary_large_image">
```

El HTML **no se cachea** en el edge, para poder contar las vistas. La página también tiene Open Graph para la home (`/`): `og:title`, `og:description`, `og:image` con logo.

### 7.3 Botones sociales

- **X:** `https://twitter.com/intent/tweet?text=<encoded>&url=<share_url>&via=...`.
- **LinkedIn:** `https://www.linkedin.com/sharing/share-offsite/?url=<share_url>`.
- **Copy link:** clipboard API nativa.
- **Download PNG:** link directo a `{share_url}.png`.
- **Copy as image:** clipboard con `ClipboardItem` (navegadores modernos).

### 7.4 Analytics de compartir

- **`share_clicks`:** evento en logs estructurados (`event: share_click, channel: linkedin`) al hacer clic en un botón.
- **`share_views`:** contador en Redis `share:views:{token}`, INCR en cada GET de `/share/{token}` (el HTML, no el PNG, que se sirve desde caché). Filtrado de bots por User-Agent y heurística simple (LinkedInBot, Twitterbot, facebookexternalhit, etc. NO incrementan).
- Los datos de Redis se persisten a `experiments.share_views` con un **job diario ejecutado por la API**, que es la única con acceso a Postgres (no en tiempo real).
- Sin PostHog, Plausible, ni píxel de tracking.

### 7.5 Email como captación de leads [v2]

**Decisión explícita:** El email se pide al inicio (opcional, "para recuperar tus días anteriores" → "to recover your previous days") y al final (opcional, "to receive your card by email"). El objetivo es doble: (1) UX de reanudación, (2) captación de leads para servicios de Data Science del autor. **El contacto comercial requiere la casilla separada `marketing_consent`**, desmarcada por defecto; enviar la tarjeta no implica consentir marketing. No hay notificación cuando alguien visita el share link. Sin doble opt-in.

---

## 8. Infraestructura

### 8.1 Docker Compose

Todos los servicios en `restart: unless-stopped`.

**Logs:** `logging: driver: json-file, options: { max-size: "500m", max-file: "3" }`. Límite de ~1.5 GB por servicio; total máximo ~7.5 GB.

**Disco lleno [v2]:** sigue sin haber healthcheck específico, pero ahora hay detección activa: `infra/scripts/disk_check.sh` (cron cada hora) registra el uso y **envía un correo por SMTP si supera el 80 %**. Procedimiento de limpieza en el runbook.

**Monitor externo [v2]:** un monitor gratuito (p. ej. UptimeRobot) vigila `https://nyctaxiapp.angelfeliz.com/` y avisa por correo si cae. Sigue sin haber Prometheus/Grafana.

### 8.2 Nginx [v2]

- Let's Encrypt con `certbot` en cron.
- `client_max_body_size 1M`.
- `proxy_intercept_errors on` + `error_page 503 /capacity-full.html`.
- **Nginx no tiene ninguna ruta hacia la API [v2.1].** Solo enruta a ShinyProxy y al servicio `share`:
    
    ```nginx
    location /share/       { proxy_pass http://share:8001/share/;                         proxy_set_header X-Client-IP $http_cf_connecting_ip; }location = /waitlist   { proxy_pass http://share:8001/waitlist;                         proxy_set_header X-Client-IP $http_cf_connecting_ip; }location /api/         { return 404; }   # la API es solo de red privada
    ```
    
- Para `/` hacia ShinyProxy: `proxy_set_header X-Client-IP $http_cf_connecting_ip;`.
- Rate limit: `limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s` para `/share/` y `/waitlist`.
- Headers de Cloudflare: confiar en `CF-Connecting-IP` (restringir el origen a las IP de Cloudflare con `set_real_ip_from`).
- `gzip on` para el HTML de `/share/`.
- **`capacity-full.html` [v2]:** página estática con un GIF/video de demo de 60–90 s, el enlace al artículo y un formulario simple "Notify me when there's room" que hace `POST /waitlist`. Se recarga sola cada 60 s.

### 8.3 ShinyProxy [v2]

```yaml
proxy:
  title: NYC Taxi Decision Simulator
  hide-navbar: true
  landing-page: /
  authentication: none
  container-backend: docker
  docker:
    internal-networking: true
    container-network: nyctaxi_api_net
  specs:
    - id: nyc-taxi-app
      container-image: ghcr.io/angelfelizr/nyc-taxi-shiny:latest
      port: 3838
      max-total-instances: 10        # ajustable hasta 12 tras el load test
      seats-per-container: 1
      allow-container-re-use: true
      container-memory-limit: 512m
      container-cpu-limit: 0.5
      container-volumes: ["/srv/nyctaxi/data:/app/data:ro"]
      container-env:
        TAXI_API_URL: http://api:8000
        API_INTERNAL_KEY: ${API_INTERNAL_KEY}
```

**Redes [v2.1]:** los contenedores Shiny solo se unen a `nyctaxi_api_net`: ven la API, pero no Postgres ni Redis. ShinyProxy también se une a esa red porque `internal-networking` lo exige, pero no recibe `API_INTERNAL_KEY`.

### 8.4 Cloudflare [v2]

- DNS proxy ON.
- SSL: Full (strict).
- Cache: assets estáticos (con `Cache-Control`) **y `/share/*.png`** (regla explícita, respeta el `Cache-Control` del origen). Nada más.
- Firewall: rate limit básico en el edge como primera capa.
- DNS del dominio remitente: registros SPF, DKIM y DMARC para el SMTP.

### 8.5 Backups

```bash
#!/bin/bash
# infra/scripts/backup.sh
set -euo pipefail
FECHA=$(date +%Y%m%d_%H%M%S)
DIR="/backups"
ARCHIVO="${DIR}/nyctaxi_${FECHA}.dump"
docker exec postgres pg_dump -Fc -U nyctaxi_app nyctaxi > "$ARCHIVO"
sha256sum "$ARCHIVO" > "${ARCHIVO}.sha256"
find "$DIR" -name "nyctaxi_*.dump*" -mtime +28 -delete
echo "$(date) Backup OK: $ARCHIVO" >> /var/log/nyctaxi-backup.log
```

Cron diario 3am. Retención 4 semanas. Sin OCI Object Storage. **[v2]** Los respaldos contienen PII (emails): permisos `700` sobre `/backups`, y la solicitud de borrado de PII (9.1) debe recordar que los respaldos antiguos expiran a los 28 días.

### 8.6 CI/CD

GitHub Actions (repo público). Jobs:

- **`test-contract`:** `spectral lint contract/openapi.yaml`.
- **`test-api`:** `testthat` con `testcontainers` (Postgres efímero).
- **`test-shiny`:** `shinytest2` flujo completo.
- **`build-api`:** build Docker + push a GHCR (`ghcr.io/angelfelizr/nyc-taxi-api:latest` y `:sha`).
- **`build-shiny`:** build Docker + push a GHCR (`ghcr.io/angelfelizr/nyc-taxi-shiny:latest` y `:sha`).
- **`build-share` / `test-share` [v2.1]:** build Docker + push a GHCR (`ghcr.io/angelfelizr/nyc-taxi-share:latest` y `:sha`) y tests del servicio.
- **`deploy`:** SSH a la VM, **descarga y verifica los archivos del release si cambió `model_version` [v2]**, luego `docker compose pull && docker compose up -d`. Solo en `main`. **[v2.1]** Termina con un smoke test de exposición: `https://nyctaxiapp.angelfeliz.com/api/health` debe responder 404 y `docker ps` solo debe publicar los puertos 80 y 443; si falla, el deploy se marca como fallido.

**Path-based triggers:** `paths:` filtra qué jobs corren según los archivos cambiados.

Downtime aceptado (~30s).

### 8.7 Auto-restart de la VM

**Acción documentada:** Verificar en la consola de Oracle Cloud que la opción "Auto-restart on failure" está activada para la instancia. Ruta: Compute → Instances → Reboot Options → Auto-restart on failure.

### 8.8 Runbook de operaciones

**Ubicación:** `docs/operations/runbook.md`. Empieza con un template y los procedimientos conocidos:

```
## Incidente: [nombre]
**Síntoma:** ...
**Diagnóstico:** ...
**Solución:** ...
**Prevención:** ...
```

Procedimientos iniciales **[v2]**: (1) limpieza de disco, (2) borrado de PII a solicitud, (3) rotación de `API_INTERNAL_KEY`, (4) qué hacer si ShinyProxy no entrega `X-Client-IP`. Se llena incrementalmente según pasen incidentes ("living document").

---

## 9. Seguridad y Privacidad

### 9.1 PII, validación y privacidad [v2]

- **PII guardada:** email (opcional, en claro, necesario para enviar la tarjeta), nombre (opcional, en claro). **La IP nunca se guarda en claro:** solo `ip_hash` (SHA-256 con sal secreta) en BD, Redis y logs. El país viene de `CF-IPCountry`.
- **Consentimiento:** dos casillas independientes y desmarcadas por defecto (recibir la tarjeta; ser contactado sobre servicios de Data Science → `marketing_consent`). Sin doble opt-in.
- **Aviso de privacidad (obligatorio antes de publicar):** página corta enlazada desde Setup, el footer y el formulario de email. Debe decir qué se guarda (email, nombre, decisiones de la simulación, IP hasheada), para qué (reanudar, enviar la tarjeta, contacto comercial solo con consentimiento), que no hay cookies de seguimiento pero **sí localStorage funcional** (`resume_code`, onboarding), cuánto se conserva (experimentos anónimos indefinidamente; PII hasta que se pida su borrado) y cómo pedir el borrado (correo de contacto).
- **Validación de email:** regex simple (`^[^@\s]+@[^@\s]+\.[^@\s]+$`) + longitud (< 254 chars). Sin verificación de MX.
- **Borrado de PII a solicitud (procedimiento manual, sin endpoint público):** `UPDATE participants SET email = NULL, name = NULL, marketing_consent = FALSE WHERE email = '<correo>'`, más eliminar de `waitlist` si aplica. Los experimentos y decisiones se conservan al quedar anonimizados. Se documenta en el runbook y se responde en un plazo razonable (objetivo: 30 días).
- **Sin cookies:** no hay política de cookies; el aviso de privacidad cubre localStorage.

### 9.2 Secretos

Variables de entorno vía `.env`, `.gitignore`. Sin gestor externo (Vault, etc.). Secretos: `POSTGRES_*`, `SMTP_URL`, `API_INTERNAL_KEY`, `IP_HASH_SALT`, `CF_API_TOKEN`. **[v2]** `IP_HASH_SALT` y `API_INTERNAL_KEY` se generan con `openssl rand -base64 32` y nunca se versionan; cambiar `IP_HASH_SALT` invalida el historial de contadores de rate limit (aceptable).

### 9.3 Red [v2]

- **La API solo es accesible desde la red privada [v2.1]:** sin puertos publicados, sin ruta en Nginx, sin endpoints públicos. Solo la consumen la app Shiny y `share` por `nyctaxi_api_net`.
- **Superficie pública mínima:** solo `/` (ShinyProxy), `/share/*` y `/waitlist` (servicio `share`). Cualquier `/api/*` responde 404.
- **Autenticación en dos capas:** `X-Internal-Key` (servicio a servicio) y `X-Resume-Code` (propiedad del experimento).
- **CORS:** solo el dominio propio + localhost en dev. Bloquea `Origin: null`.
- **Postgres:** puerto NO expuesto al host. Solo en `nyctaxi_data_net`, accesible únicamente para la API. Los contenedores Shiny no pueden alcanzarlo.
- **Logs:** JSON estructurado con `logger`. Contenido de requests incluido (sin password, no hay), **pero sin `X-Resume-Code`, `X-Internal-Key` ni emails en claro** (se enmascaran).

---

## 10. Testing

- **Cobertura:** ~60% global. 100% en módulos críticos: `sensitivity.R`, `rate_limit.R`, `migrations.R`, `simulate.R`, **`internal_auth.R`, `client_ip.R`, `outcome.R` [v2]**.
- **API:** `testcontainers` con Postgres efímero por suite.
- **Shiny:** `shinytest2` flujo completo Setup → Trips → Results + estados de error.
- **Tests de estados de error:** 429 (rate limit), 403 (clave interna o `resume_code` inválidos), 404 (experimento no existe), 409 (decisión duplicada con payload distinto), 503 (Postgres caído, modelo no cargado, SMTP falló). En Shiny, `shinytest2` simula un `httr2` que devuelve 429 y verifica que la UI muestra el mensaje correcto.
- **Tests nuevos [v2]:**
    - `outcome`: una prueba por cada rama (`no_rides`, `beat_model`, `tied_model`, `beat_baseline`, `lost_to_baseline`) y el caso `seed_is_custom` (nunca texto de victoria).
    - Rate limit con IP real: dos clientes con distinta `X-Client-IP` tienen contadores independientes; una `X-Client-IP` sin `X-Internal-Key` válida se ignora.
    - Ninguna respuesta pública (`/share/*`, PNG) contiene el `experiment_id` ni emails.
    - El PNG de un experimento no `finished` devuelve 404.
    - Aislamiento de sesión con `allow-container-re-use` (sin estado global).
    - Atajos: la flecha solo preselecciona; Enter confirma.
    - **Exposición de red [v2.1]:** (a) smoke test post-deploy: `/api/*` responde 404 desde Internet; (b) `docker ps` solo publica los puertos 80 y 443; (c) desde un contenedor Shiny, la conexión a `postgres:5432` y `redis:6379` falla; (d) sin `X-Internal-Key` válida, cualquier endpoint de la API responde 403; (e) el contenedor `share` no tiene variables `POSTGRES_*`.
- **Sin tests de regresión visual.** Sin `pa11y`/`axe-core` en CI (manual). Sin snapshot dorado para `/sensitivity`.
- **Checklist manual en móvil [v2]:** flujo Setup → Trips → Results y página `/share` en un viewport de 390 px y en el navegador integrado de LinkedIn.
- **Load testing:** `shinyloadtest` perfil 1, 10, 20 usuarios concurrentes. En CI, no bloquea merge. Mide también la mediana de duración de jornada y la latencia p95 de `/sensitivity`.

---

## 11. Observabilidad

- **Logs:** JSON estructurado. Cada request con `method, path, status, duration_ms, correlation_id, ip_hash`.
- **`/metrics`:** JSON con contadores: `experiments_started`, `experiments_finished`, `experiments_abandoned`, `shares_generated`, `share_views_total`, `sensitivity_cache_hits`, `sensitivity_cache_misses`, **`png_cache_hits`, `png_cache_misses`, `waitlist_signups`, `capacity_503_total` [v2]**.
- **Sin Prometheus/Grafana.** Alertas mínimas **[v2]**: monitor externo de disponibilidad y `disk_check.sh` por correo (8.1). Nada más.
- **Timing de `/sensitivity`:** siempre loggeado.
- **Sin dashboard interno.** Consultas SQL ad-hoc cuando se necesiten métricas de negocio.

---

## 12. Accesibilidad

- **Objetivo:** WCAG AA.
- **Contraste verificado** (a validar con WebAIM).
- **`prefers-reduced-motion`** respetado.
- **`aria-label`** en gráficos ggiraph y elementos clave.
- **No depender solo del color [v2]:** la comparación final usa icono y texto además de verde/rojo.
- **Mapa Leaflet NO navegable con teclado** (intencional). Alternativa: selectize con búsqueda por nombre.
- **Sin pruebas con lectores de pantalla reales.**
- **Atajos de teclado [v2]:** flecha izquierda/derecha preseleccionan y Enter confirma en Trips; `?` para ayuda; Escape para cerrar modales. Documentados en el footer con ícono de teclado clickeable.
- **Objetivos táctiles [v2]:** botones principales de al menos 44×44 px.

---

## 13. Portafolio y Narrativa

- **Idioma [v2]:** la app, los mensajes de error, las tarjetas, el README y el artículo Quarto de cara al público van en **inglés** (audiencia de LinkedIn/X y reclutadores internacionales). Los ADRs y el runbook pueden seguir en español. Todos los textos de la UI viven en `app/R/strings.R`.
- **README del repo actual:** narrativa técnica + despliegue. Headline: qué es y cómo se despliega. Incluye el GIF/video de demo y el enlace a la app.
- **Demo [v2]:** **GIF o video de 60–90 s obligatorio antes de publicar** (reemplaza el "sin video demo" de la v1). Se usa en el README, en la landing, en la página `capacity-full.html` y en el anuncio. Razón: con aforo limitado y una jornada de varios minutos, quien llega cuando está llena, o con poco tiempo, debe poder ver el producto igualmente.
- **Artículo Quarto:** detalle técnico de decisiones. Se publica al final del proyecto. URL planeada: `https://angelfelizr.github.io/NycTaxi/investigation-phases/12-shiny-app.html`.
- **Landing principal:** `https://angelfelizr.github.io/NycTaxi/` — narrativa de negocio. Mismo contenido que el README del repo original (`github.com/AngelFelizR/NycTaxi`).
- **Aviso de privacidad [v2]:** publicado y enlazado (ver 9.1).
- **Sin `CONTRIBUTING.md`.**
- **ADRs sí:** `docs/decisions/ADR-NNN.md` con cada decisión importante.
- **Sin métricas públicas de uso.**
- **Sin publicar datasets procesados.**

---

## 14. Fases de Implementación

### Fase 0 — Contrato y estructura

**Entregable:** Estructura del monorepo, `.env.example`, `contract/openapi.yaml` (API privada, 18 endpoints) y `contract/share.openapi.yaml` (servicio público, 3 rutas).

**Prompt sugerido:**

> "Crea la estructura del monorepo `nyc-taxi` con las carpetas de primer nivel descritas en la sección 1.3. Añade `README.md`, `CHANGELOG.md`, `LICENSE` (MIT), `.gitignore` (R, Docker, .env). Escribe `.env.example` con todas las variables (POSTGRES__, REDIS__, TAXI_API_URL, API_INTERNAL_KEY, IP_HASH_SALT, APP_VERSION, MODEL_VERSION, ENV, SMTP_URL, CF_API_TOKEN). Escribe `contract/openapi.yaml` en OpenAPI 3.1 con los 18 endpoints de la API privada (sección 5.2) y `contract/share.openapi.yaml` con las 3 rutas públicas del servicio `share`, incluyendo los esquemas de seguridad `X-Internal-Key` y `X-Resume-Code` y el campo `outcome`. Incluye el JSON de ejemplo para cada request/response. Valida con `spectral lint`. Commit inicial: `chore: initial monorepo structure and API contract`."

**Criterio de listo:** El YAML valida con `spectral lint` sin errores.

### Fase 1 — API base (plumber2)

**Entregable:** API con `/health`, `/predict`, `/recommend-start`, `/validate-trip-start` funcionales. Modelos cargados. Middleware de autenticación interna.

**Prompt sugerido:**

> "Crea la API plumber2 en `api/` siguiendo la estructura de la sección 5.1. Implementa `/health`, `/predict`, `/recommend-start`, `/validate-trip-start` y el middleware `internal_auth.R` (X-Internal-Key; sin la clave, 403). La API nunca se publica al host ni a Nginx. Los modelos se cargan en el proceso principal con `qs2::qs_read()` desde un volumen de solo lectura y se comparten con `mori::share()`. Usa `pool` para Postgres. Los tests usan `testcontainers`. Documenta cada endpoint con comentarios roxygen. Criterios de listo: `curl` responde < 100ms con modelos cargados, y el RSS de la API con modelos es < 1.2 GB (si no, ajustar el límite)."

### Fase 2 — Sensibilidad

**Entregable:** `/sensitivity` con caché Redis y grid configurable.

**Prompt sugerido:**

> "Implementa `/sensitivity` portando `select_zone_with_high_change()` y `compute_decision_grid()` (derivada de `plot_decision_boundary()` pero sin plotting). Devuelve 3 dataframes (original, PU, DO) + meta. Caché Redis con clave `sens:{exp}:{trip}:{pu}:{do}` TTL 1h. Grid 50×50 por defecto, 30×30 si header `X-Device: mobile`. Tests de rendimiento: < 500ms con caché, < 2.5s en frío."

### Fase 3 — Persistencia y experimentos

**Entregable:** Migraciones aplicadas, endpoints de experimentos funcionales, rate limit con IP real, `outcome` y percentil, distribución de referencia.

**Prompt sugerido:**

> "Aplica `migrations/001_init.sql` (4 tablas). Implementa `POST /experiments` que corre las 3 trayectorias (user inicial vacío, policy, baseline), las guarda en `decisions` y devuelve el `resume_code` una sola vez; marca `seed_is_custom` si la semilla fue editada. Todos los endpoints `/experiments/{id}/...` exigen `X-Resume-Code` contra `resume_code_hash`. Rate limit 3/día/IP real (hash) con Redis y `client_ip.R`. `GET /experiments/{id}/state` reconstruye estado desde `decisions`. `POST /decisions` idempotente. `POST /finish` calcula los 3 wages (definición de la sección 3.9), `outcome` (precedencia de la sección 3.10) y `user_percentile`. Escribe `tools/build_reference_distribution.R` que simula política y baseline en ≥ 1,000 semillas por compañía y genera `ReferenceDistribution.qs2`. `POST /abandon` marca como abandonado. `POST /share-email` envía el PNG por SMTP (máx. 3 por experimento). `GET /share-data/{token}` devuelve los datos agregados del resultado sin PII ni `experiment_id`, y `POST /waitlist` guarda emails de la lista de espera (ambos solo internos)."

### Fase 4 — UI Setup

**Entregable:** App Shiny con `theme.R`, `constants.R`, `strings.R`, `mod_header`, `mod_setup`, `mod_confirm_modal`. Leaflet bidireccional. Reenvío de IP verificado.

**Prompt sugerido:**

> "Crea `app/` con estructura modular. Implementa `theme.R`, `constants.R` (lee desde `/srv/nyctaxi/data`), `strings.R` (todos los textos en inglés), `api_client.R` (con X-Internal-Key, X-Client-IP, X-Resume-Code), `mod_header`, `mod_setup`, `mod_confirm_modal`. Usa `layout_columns` de bslib. Leaflet bidireccional con selectize. Casillas de email y de marketing separadas y desmarcadas. Modal con el `resume_code` tras Start The Day. Sin `renderUI` excepto en modal. `shinytest2` prueba el flujo Setup → modal → Start Day y **verifica que ShinyProxy entrega `X-Client-IP` al contenedor** (si no, implementar el Plan B de la sección 5.4). Criterio: la app arranca en < 3s."

### Fase 5 — UI Trips

**Entregable:** Simulación interactiva con KPIs, gráficos acumulados, sensibilidad, atajos de teclado seguros.

**Prompt sugerido:**

> "Implementa `mod_trips`, `mod_trip_card`, `mod_sensitivity`. KPIs con `textOutput` + `updateTextInput`. Gráficos acumulados con `renderGirafe` (3 curvas user/policy/baseline, sin color comparativo). `renderLeaflet` con `leafletProxy` para actualizar rutas. `mod_sensitivity` usa `updateSelectizeInput(server = TRUE)` y `renderGirafe`. Atajos: flechas preseleccionan, Enter confirma; botones táctiles de 44 px; pistas de teclado ocultas en táctiles. Pending time como barra de progreso con colores. `shinytest2` prueba el flujo completo."

### Fase 6 — UI Results y Share

**Entregable:** Results con 6 KPIs y percentil, botones de compartir, servicio `share` (PNG con caché y HTML con CTA), feedback modal, aviso de privacidad.

**Prompt sugerido:**

> "Implementa `mod_results` con máximo 6 KPIs, 3 curvas finales con color + icono, línea de percentil y la insignia de semilla personalizada. Crea el servicio `share/` (plumber2, imagen propia, sin credenciales de Postgres, datos vía `GET /share-data/{token}` de la API privada). `GET /share/{token}` devuelve HTML con Open Graph estático **y cuerpo visible con el botón 'Play your own day'** (sin JS). `GET /share/{token}.png` genera el PNG 1200×630 con `patchwork` + `ragg` (fuentes del sistema), sin `experiment_id`, con etiqueta según `outcome`, solo si el experimento está `finished`, con `Cache-Control` y caché en Redis. Textos de compartir según la tabla 6.6. `mod_feedback` con rating + comentario + email opcional. Publica el aviso de privacidad. Valida con Post Inspector de LinkedIn y configura SPF/DKIM/DMARC."

### Fase 7 — Infra y despliegue

**Entregable:** Dockerfiles, compose, ShinyProxy config, Nginx config, scripts de backup y disco, GitHub Actions.

**Prompt sugerido:**

> "Escribe Dockerfiles multi-stage para API, Shiny y share. `docker-compose.yml` con Postgres, Redis, API, share, ShinyProxy y Nginx, con las tres redes de la sección 1.0 (la API solo en `api_net` y `data_net`, sin `ports:`), los límites de la sección 1.1 y 2 GB de swap. `application.yml` de ShinyProxy con `max-total-instances: 10` y el volumen de datos en solo lectura. `nginx.conf` que solo enruta `/` (ShinyProxy) y `/share/*` y `/waitlist` (servicio share); `/api/*` responde 404, con interceptación 503 y `capacity-full.html` (demo + lista de espera). Regla de caché de Cloudflare para los PNG. Scripts `backup.sh`, `restore_test.sh`, `disk_check.sh` y el de descarga y verificación de modelos. Monitor externo de disponibilidad. GitHub Actions para build+push+deploy con path-based triggers. Primer despliegue en VM ARM."

### Fase 8 — Load testing y endurecimiento

**Entregable:** Reporte de carga, ADRs, ajuste de límites.

**Prompt sugerido:**

> "Ejecuta `shinyloadtest` con 1, 10, 20 usuarios. Documenta en README: memoria usada, latencia p95 de `/sensitivity`, mediana de duración de jornada (objetivo ≤ 12 min) y aciertos de caché del PNG. Ajusta `max-total-instances` (techo 12, solo con holgura ≥ 2 GB). Prueba accesibilidad con `pa11y` local (no CI) y el checklist manual en móvil. Verifica contraste AA con WebAIM. Escribe ADRs para las decisiones más importantes en `docs/decisions/`. Actualiza `docs/operations/runbook.md` con los incidentes encontrados."

### Fase 9 — Contenido y publicación

**Entregable:** Demo GIF/video, artículo Quarto, anuncio en redes.

**Prompt sugerido:**

> "Graba el GIF/video de demo de 60–90 s y colócalo en README, landing y `capacity-full.html`. Escribe artículo Quarto con las decisiones técnicas en `docs/investigation-phases/12-shiny-app.qmd`. Actualiza README con narrativa de despliegue. Publica en `angelfelizr.github.io/NycTaxi/`. Anuncia en LinkedIn y X. Recopila métricas ad-hoc con SQL."

---

## 15. Archivos de Referencia Externos

|Archivo|Tamaño|Uso|
|---|---|---|
|`AcceptRejectPolicyFitted.qs2`|345 MB|Modelo XGBoost|
|`DecisionTreeWfFitted.qs2`|2.84 MB|Modelo de validación|
|`ValidHoursToStartWorking.qs2`|301 B|Lookup determinista|
|`NycTrips2024_sample_week.parquet`|188 MB|Datos de simulación|
|`ZonesShapes.qs2`|1 MB|Geometrías para Leaflet|
|`ReferenceDistribution.qs2` **[v2]**|por definir (pequeño)|Distribución de wages de política y baseline por compañía, para el percentil|

**Fuente:** `https://github.com/AngelFelizR/NycTaxiApp/releases/tag/v0.0.1-data`. **[v2]** El script de deploy los descarga una vez a `/srv/nyctaxi/models` y `/srv/nyctaxi/data`, verifica el SHA-256 y los monta en solo lectura. Los contenedores no descargan nada en runtime ni los incluyen en la imagen.

---

## 16. Prompt de Arranque Sugerido

Copia esto como primer mensaje en un chat nuevo:

> "Voy a construir un **monorepo** en R con Shiny + plumber2 + PostgreSQL + Redis, llamado NYC Taxi Decision Simulator. El monorepo contiene la API (imagen Docker `nyc-taxi-api`), la app Shiny (imagen Docker `nyc-taxi-shiny`), y toda la infraestructura (Nginx, ShinyProxy, Postgres, Redis). Un solo CI/CD, un solo semver, un solo `docker-compose.yml`. Tengo un documento maestro de decisiones (versión 2, ya corregido tras una evaluación de diseño) que voy a pegar a continuación. Quiero que actúes como arquitecto de software senior y me guíes paso a paso por las fases de implementación. No cuestiones las decisiones ya tomadas a menos que detectes una contradicción técnica. Empieza por confirmar que entiendes la arquitectura de monorepo y el modelo de seguridad (la API es accesible solo desde la red privada y solo la consumen la app Shiny y el servicio público mínimo `share`; `X-Internal-Key` y `X-Resume-Code`), y luego arrancamos con la Fase 0. Documento maestro: [pegar este documento completo]"

---

## 17. Decisiones Diferidas (documentar como ADR cuando se aborden)

- Algoritmo exacto de generación de `resume_code` y `share_token`.
- Formato exacto del HTML de share (fuentes, layout) y copy de la frase de contexto.
- Estructura del modal de confirm (contenido exacto).
- Estrategia de filtrado de bots para `share_views`.
- Detalles de la descarga de modelos en el deploy (reintentos).
- Mensaje exacto del pop-up de onboarding.
- Contenido textual exacto del pop-up de la opción avanzada de semilla.
- Redacción final del aviso de privacidad. **[v2]**
- Número de semillas y estratificación exactos de `ReferenceDistribution.qs2`. **[v2]**
- Plan B de IP (token HMAC) solo si ShinyProxy no reenvía `X-Client-IP`. **[v2]**

Estas se resuelven en el momento de implementar cada fase, no bloquean el arranque.

---

## 18. Índice de ADRs a Crear

|ADR|Decisión|Sección|
|---|---|---|
|ADR-001|Monorepo vs. multi-repo|1.2|
|ADR-002|PostgreSQL local vs. Supabase|2.1|
|ADR-003|4 tablas (incluye `waitlist`) vs. esquema más granular|2.2|
|ADR-004|Write-through vs. batch en decisiones|2.5|
|ADR-005|Modelos en release externo, descargados en el deploy y montados de solo lectura|4.5|
|ADR-006|`mori` para shared memory|4.1|
|ADR-007|Cero `renderUI` en estructura|6.1|
|ADR-008|Leaflet bidireccional|6.5|
|ADR-009|PNG generado server-side vs. client-side, con caché en Redis y Cloudflare|7.1|
|ADR-010|Un solo `share_token` con query params|2.4|
|ADR-011|Sin firma en `share_token`|2.4|
|ADR-012|Cloudflare al frente|8.4|
|ADR-013|Sin Prometheus/Grafana (con alertas mínimas)|11|
|ADR-014|Sin tests de regresión visual|10|
|ADR-015|Retención de experimentos indefinida; PII borrable a solicitud|2.3, 9.1|
|ADR-016|Autenticación `X-Internal-Key` + `X-Resume-Code` y reenvío de IP real (con Plan B)|2.4, 5.4|
|ADR-017|API solo en red privada; servicio público mínimo `share`; segmentación en tres redes Docker|1, 5.10, 8.2|
|ADR-018|Semilla personalizada = resultado no oficial; `outcome` calculado en servidor|3|
|ADR-019|Distribución de referencia y percentil|4.6|
|ADR-020|Privacidad: `ip_hash`, consentimientos separados, aviso, borrado manual|9.1|
|ADR-021|Idioma único (inglés) de cara al usuario|13|
|ADR-022|Atajos de teclado: preseleccionar + Enter|6.5|
|ADR-023|Presupuesto de recursos: 10 instancias (techo 12), swap, límites de API y Postgres|1.1|
|ADR-024|Color: sin semáforo en Trips, color + icono solo en Results|3.11|
|ADR-025|Definición de wage y regla de empate|3.9, 3.10|
|ADR-026|Demo obligatorio y página de capacidad con lista de espera|8.2, 13|