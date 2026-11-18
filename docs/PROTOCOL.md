# Wire protocol v1

Typed JSON over TLS 1.3 with client certificates; every request and successful response requires `X-DeviceBridge-Version: 1`. Unsupported versions receive 426. Errors are `{code,message}` with HTTP status. The protocol has no shell, sync administration or credential export endpoint. Future additive fields are allowed; incompatible changes require version negotiation/update rather than implicit use.

| Method/path | Authorization | Result |
| --- | --- | --- |
| POST `/v1/pair` | valid certificate + single-use invitation token | pending request; identity/name only, no roots |
| GET `/v1/pair` | certificate belonging to that request | pending/paired status |
| GET `/v1/device` | paired key | stable ID, name, version, feature IDs |
| GET `/v1/files/roots` | paired key | only browse-authorized root IDs; never local absolute paths |
| GET `/v1/files/list` | browse(root) | lazy metadata page, opaque numeric page token |
| GET `/v1/files/stat` | browse(root) | metadata only |
| GET `/v1/files/manifest` | read(root) | bounded recursive SHA-256 manifest, no file contents |
| GET `/v1/files/range` | read(root), expiry, quota | up to 1 MiB, `X-Chunk-SHA256` |
| GET `/v1/files/preview` | read(root), expiry, quota | up to 64 KiB, same range/checksum schema |

Filesystem query fields: `root`, `path` relative to the export; lists also accept `limit` (1–500), `page`; ranges/previews require decimal `offset`, `length`. All requests authenticate independently, including on persistent TLS connections. Root IDs cannot be substituted for local paths.

Pairing invitation fields: `{version,id,name,token,expires}`. ID is SHA-256 of DER SubjectPublicKeyInfo, lowercase hex. Token is 32 cryptographically random bytes in unpadded base64url; only its hash is stored by the issuer. Transfer this invitation out of band; it is never broadcast by mDNS. Owner approves the recipient's full ID and selected roots through the local CLI. Recipient finishes after owner approval; no inbound root grants are implied.

DNS-SD: PTR `_devicebridge._tcp.local.`, SRV port, TXT `v=1,id=<key-id>`, local A record. Advertised names/addresses are untrusted. The browser uses the on-link datagram source and verifies the pinned key during the TLS handshake. No remote peer IP is needed for ordinary `pair`, `resolve`, `list` or `pull` operations.
