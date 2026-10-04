# plumber2 API contract expected by the Shiny client

Base URL: `TAXI_API_URL` (default `http://127.0.0.1:8000`). JSON in/out.
Errors: any non-2xx; if the body has `{"message": "..."}` it is shown to the user.
Adjust `app/R/api_client.R` if your real routes/fields differ -- it is the only file that knows them.

| Method | Path | Body | Response |
|---|---|---|---|
| GET  | `/options` | - | `{"companies":["Lyft","Uber"],"zones":["Queens - Saint Albans",...],"default_start_dt":"2024-05-12 00:00"}` |
| POST | `/validate` | `{"company","start_dt","start_zone"}` | `{"optimal":false,"company_hint":"Use Uber for better results","datetime_hint":"Start at 2024-05-12 20:00 for better results","message":""}` (hints empty/null when OK; `message` e.g. "Conditions are Perfect to get best results") |
| POST | `/days` | `{"company","start_dt","start_zone"}` | day state |
| POST | `/days/{day_id}/decisions` | `{"accept":true}` | day state (next trip, or `finished:true`) |
| POST | `/days/{day_id}/sensitivity` | `{"pickup_zone"?,"dropoff_zone"?}` | array of `{"scenario","trip_minutes","min_pay"}` |

## Day state
```json
{
  "day_id": "abc123",
  "finished": false,
  "clock": "2024-05-12 00:00:00",
  "pending_hours": 8.0,
  "pct_following_policy": 100,
  "history": [{"step":0,"user":0,"policy":0}],
  "trip": {
    "pickup_zone": "Queens - Saint Albans",
    "dropoff_zone": "Manhattan - Alphabet City",
    "current_location": "Queens - Saint Albans",
    "miles": 9, "minutes": 25, "pay": 20,
    "recommendation": "accept"
  }
}
```
When `finished` is true, `trip` may be null; the UI moves to the dashboard.

## Status: transitional

This file documents only the routes the Shiny client uses **today**
(`app/R/api_client.R` is its single consumer). It is not the project
contract: the authoritative OpenAPI 3.1 specs live in
`contract/openapi.yaml` (private API, 18 endpoints, `X-Internal-Key` /
`X-Resume-Code`) and `contract/share.openapi.yaml` (public `share`
service). Expect this file to be replaced once the UI talks to the real
endpoints (phases 4-6 of `04 - Documento Maestro de Decisiones del
Proyecto.md`, the source of truth).
