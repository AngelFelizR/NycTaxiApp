# First deploy checklist

Everything in phase 7 that cannot be done from inside this repository: accounts,
dashboards, DNS and the VM itself. Each item says who does it, what exactly to
create, and how to tell it worked. Nothing here is automatable from CI without
credentials, which is why it is a checklist rather than a job.

Companion documents: `runbook.md` for what happens *after* the first deploy,
`../../AGENTS.md` for what phase 7 built.

---

## 1. The data release must be verifiable

`infra/scripts/fetch-assets.sh` refuses to install anything it cannot check
(section 4.5), and the deploy job runs it before touching the stack. As of
today the `v0.0.1-data` release is **not deployable**, for two reasons: it
publishes no `SHA256SUMS`, and it does not carry `ReferenceDistribution.qs2`
(so `/finish` answers 503 and a day can never end).

Both files already exist on the workstation — they were never *published*:

```sh
ls -la ~/nyctaxi/models/ReferenceDistribution.qs2   # 12 kB, generated 2026-10-05
```

**What has to be uploaded** (six assets plus the manifest; `make-manifest.sh`
knows the list, and it handles the fact that the files live in two
directories):

```sh
./infra/scripts/make-manifest.sh        # writes ./SHA256SUMS with all six

gh release upload v0.0.1-data \
    SHA256SUMS \
    ~/nyctaxi/models/ReferenceDistribution.qs2 \
    --clobber
```

No `gh`? The web UI works too: GitHub → Releases → `v0.0.1-data` → *Edit* →
drag the two files in. What matters is that **both** end up on that tag.

**Verify before believing it** (this is the step the deploy runs; it must
exit 0 and print `assets ready`):

```sh
MODELS_DIR=/tmp/m DATA_DIR=/tmp/d ./infra/scripts/fetch-assets.sh v0.0.1-data
echo $?    # 0 = ok; anything else = the release is still wrong
```

Until that passes, every deploy stops at this step **by design**. Do not work
around it by setting `SKIP_VERIFY`: 4.5 asks for verification precisely
because a half-written 345 MB policy file would let the API start and serve
garbage.

The verifier itself is covered by
`./infra/scripts/test-fetch-assets.sh`, a hermetic self-test (six invented
files, no network, no real `.env`) that checks the happy path, the idempotent
re-run, a manifest with entries missing -- it must name **all** of them at
once rather than fail one at a time -- and a wrong hash, which must leave the
destination untouched.

---

## 2. The VM

Oracle Cloud ARM instance, 2 OCPU / 12 GB (section 1.1), Ubuntu 24.04 or
Debian 12 with Docker and Docker Compose v2.

```sh
# 2 GB of swap as the safety net (1.1). The stack peaks near 8.7 GB with 10
# Shiny instances and the page cache needs room.
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Directory layout the compose file mounts (4.5, 15).
sudo mkdir -p /srv/nyctaxi/models /srv/nyctaxi/data /backups
sudo chmod 700 /backups

# The repository: CI runs `git pull --ff-only` here before bringing the stack
# up, so it has to be a clone with a deploy key that can read it.
git clone git@github.com:AngelFelizR/NycTaxiApp.git ~/NycTaxiApp
cd ~/NycTaxiApp && cp .env.example .env && ${EDITOR:-nano} .env
```

`.env` on the VM is the real one: `POSTGRES_PASSWORD`, `API_INTERNAL_KEY`,
`IP_HASH_SALT`, `SMTP_URL`, and `MODEL_VERSION`. It is gitignored and never
transmitted by CI.

**Cron:**

```cron
0  3 * * * cd ~/NycTaxiApp && ./infra/scripts/backup.sh
0  * * * * cd ~/NycTaxiApp && ./infra/scripts/disk_check.sh
# certbot renew (section 8.2); installs with the nginx image or the host package
0  */12 * * * certbot renew --quiet && docker exec nyctaxi-nginx nginx -s reload
```

**Auto-restart** (8.7): in the Oracle Cloud console, Compute → Instances →
Reboot Options → enable *Auto-restart on failure*. There is no file for this;
it is a checkbox.

**Verify:** `df -h /srv/nyctaxi /backups`, `swapon --show`, `docker compose
version`.

---

## 3. GitHub Actions secrets

| Secret | Value |
|---|---|
| `VM_HOST` | the VM's public IP or DNS name |
| `VM_USER` | the SSH user (e.g. `ubuntu`) |
| `VM_SSH_KEY` | private key whose public half is in `~/.ssh/authorized_keys` on the VM, and which can read the repository |

GHCR needs nothing extra: the workflow pushes with `GITHUB_TOKEN`.

**Verify:** the `deploy` job on a push to `main` reaches the VM and the smoke
test at its end passes.

---

## 4. DNS

Zone for `angelfeliz.com`:

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `nyctaxiapp` | VM public IP | **Proxied** (orange cloud) |
| TXT | `@` | SPF — see below | DNS only |
| TXT | `<selector>._domainkey` | DKIM public key — see below | DNS only |
| TXT | `_dmarc` | DMARC — see below | DNS only |

### 4.1 SPF

Whatever the SMTP provider gives you, in one TXT record on `@` (or on the
subdomain you send from):

```
v=spf1 include:<provider-sending-range-or-include> -all`
```

`SMTP_FROM` in `.env` must be an address on this domain. `-all` (hard fail)
once you are sure nothing else sends mail from it.

### 4.2 DKIM

The provider generates a key pair and gives you the public half:

```
<selector>._domainkey   TXT   "v=DKIM1; k=rsa; p=<base64-public-key>"
```

The `<selector>` is what the provider puts in the `DKIM-Signature` header.
Until this record exists, providers accept the mail and then discard it — the
symptom is "the API says the card was sent and nobody receives it".

### 4.3 DMARC

```
_dmarc   TXT   "v=DMARC1; p=quarantine; rua=mailto:angel.esteban.feliz@gmail.com; pct=100"
```

Start with `p=none` if you want to read the reports first, then tighten to
`quarantine` and finally `reject`.

### 4.4 Verify

```sh
dig +short TXT angelfeliz.com | grep spf
dig +short TXT <selector>._domainkey.angelfeliz.com
dig +short TXT _dmarc.angelfeliz.com

# End to end: send yourself a card and then
# https://www.mail-tester.com/  or check the headers of what arrived
grep -i '^(spf|dkim|dmarc)' -i <message-headers>
```

---

## 5. Cloudflare (section 8.4)

Dashboard → the domain →:

1. **SSL/TLS → Overview → Full (strict).** The origin presents a Let's
   Encrypt certificate for `nyctaxiapp.angelfeliz.com`.
2. **Cache → Cache Rules → Create rule**
   - Name: `share-card-png`
   - Expression: `(http.request.uri.path matches "^/share/.*\\.png$")`
   - Cache eligibility: **Eligible for cache**
   - Leave Edge TTL to *Respect Origin* — Nginx already sends
     `public, max-age=86400, s-maxage=604800` (7.1), and the HTML of
     `/share/{token}` sends `no-store`, so it is never cached by accident.
3. **WAF → Tools → Rate limiting rules**
   - `/share/*` and `/waitlist`: 10 requests/second per IP, block for 60 s.
     Nginx already enforces this at the origin (`limit_req`); the edge rule is
     the first layer (8.2, 8.4).
4. **DNS records are already listed in section 4.**

Not automatable here: `CF_API_TOKEN` in `.env` exists for a future script, and
the whole configuration is currently done by hand. If you automate it later,
`infra/` is the place for the script.

---

## 6. External availability monitor (8.1)

A free tier from UptimeRobot (or equivalent):

| Monitor | URL | Interval |
|---|---|---|
| Home | `https://nyctaxiapp.angelfeliz.com/` | 5 min |
| Card | `https://nyctaxiapp.angelfeliz.com/share/<any-old-token>` | 5 min |

The home monitor is the one §8.1 asks for. Alert by email to the address from
section 4.3 so it lands where somebody reads it.

**Do not** point a monitor at `/api/health`: Nginx answers 404 for anything
under `/api/` on purpose (1.0), and a monitor that expects 200 there would page
you forever.

---

## 7. Post-deploy smoke test

Run this from a machine that is not the VM:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://nyctaxiapp.angelfeliz.com/api/health   # 404
curl -s -o /dev/null -w '%{http_code}\n' https://nyctaxiapp.angelfeliz.com/             # 200
curl -s -o /dev/null -w '%{http_code}\n' https://nyctaxiapp.angelfeliz.com/waitlist      # 405/422, never 502
docker ps --format '{{.Names}} {{.Ports}}'    # only nginx: 80 and 443
```

Then play a short day and check, in order: the session gets a resume code, the
shift finishes, Results renders, **the share card opens**, and
`POST /experiments/{id}/share-email` delivers a real email (that is the only
test that proves sections 4.2 and 5.6 together).

---

## 8. What is left manual, for now

- SPF/DKIM/DMARC changes and the Cloudflare rules (sections 4 and 5) live in
  dashboards, not in this repository.
- The availability monitor (section 6) is a third-party account.
- `docs/investigation-phases/` (phase 9) and the load test (phase 8) both need
  this deploy to exist first.
