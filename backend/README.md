# YPerson local backend

The implementation uses only Node.js built-ins and keeps development state in memory. It exposes the approved API and stores no Contacts address book, raw photos, camera frames, precise location, meeting notes, biometric data, or analytics payloads.

Start from the repository root:

```bash
node backend/server.mjs
```

Smoke checks:

```bash
curl -i http://127.0.0.1:8080/health
curl -i http://127.0.0.1:8080/config
curl -i -X POST http://127.0.0.1:8080/sync \
  -H 'Content-Type: application/json' \
  --data '{"installationID":"review-installation","bearer":null,"apnsToken":null,"operation":"refresh","card":null,"exchangeToken":null,"moderationCategory":null}'
```

`GET /config` is public, accepts no PII, returns a stable ETag, and contains only version, minimum contract, maintenance, feature availability, sponsored template display data, privacy/support URLs, moderation categories, and the analytics kill switch. The iOS client rejects unknown top-level, feature, or sponsored-template keys so this endpoint cannot remotely expand permissions, data collection, tracking, or retention.

Production HTTPS hosting, jurisdiction, persistence, authentication, APNs credentials, signing keys, moderation operations, and processor agreements remain release blockers.
