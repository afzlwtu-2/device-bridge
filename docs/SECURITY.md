# Security boundaries and current limits

## Enforced

- Stable Ed25519 identities, self-signed certificates and TLS 1.3 mutual certificate possession. Client checks the exact SHA-256 public-key pin from the out-of-band invitation; IPs and mDNS names never establish trust. The server validates client certificates at TLS and authorizes their key IDs on every operation.
- Five-minute, 256-bit, single-use invitation. Recipient explicitly accepts the fingerprint and submits its identity; owner must separately approve the pending identity and roots. Pending requests expire. There is no unauthenticated file access and no automatic grant for a new feature.
- Per-root browse/read grants, expiry, cumulative read quotas, immediate revocation, private local audit events. No write/upload/root capability is advertised or granted.
- Explicit approved LAN interface and local private IPv4/CIDR. No HTTP proxy, redirect, internet/relay/cellular fallback, public discovery, SSH config edits or Tailscale changes. DNS-SD packets are bounded, on-link hints and authenticated before use. Cached endpoints expire after 30 seconds and are scoped to source address/subnet/interface.
- Scoped descriptor-based filesystem access; no default exports; bounded paging, previews, ranges and manifest scans; no unsafe path/archive extraction. Data stages privately and requires final hashes and atomic no-overwrite publication.
- SQLite/keys are inside a private state directory. Android disables app backup. API responses/audits contain no private keys, invitation tokens or Syncthing credentials.
- Phone safety: no root commands, system files/partitions, boot/AVB/verity changes, root modules or SELinux changes. Temporary root never grants authorization.

## Limits to retain visibly

- No external security review yet. `govulncheck` reported no known Go vulnerabilities on 2026-11-18; this is not a security audit. APKs use a development signing key, including the optimized build.
- Route cost is an explicit user declaration, not independent OS-proven metering on Linux/Termux. The current direct provider binds its source IP and denies off-subnet endpoints. OS routing/VPN interference is not yet independently attested; do not claim protection against hostile routes or same-UID local compromise. Android observes Wi-Fi loss and address changes. Installed-app foreground transfer and normal-UID operation passed; background/doze/hotspot acceptance remains pending.
- IPv4 DNS-SD only; multicast filtering can still make a new peer unavailable. Bounded retries and short authenticated caches do not bypass network approval. No public registry or silent remote fallback.
- Certificate rotation, renewal UX, rejection/removal/re-pair UX, audit retention, per-peer rate limits and transfer-history persistence are unfinished. Server concurrency, body/header sizes, transfer sizes and manifest time are bounded.
- Root exports bind at agent startup; changing an export requires an explicit restart. Uploads and SAF-backed serving are not implemented. SAF export copies verified app-private downloads into a user-chosen destination; partial export failure leaves the private verified copy intact.
- Directory source consistency is per manifest/per file, not an atomic snapshot. A changed/corrupt resumed file blocks publication and retains staging; the user must choose a fresh destination after inspection. Maximum 20,000 entries, depth 128, 100 GiB/manifest in this first slice. No tar/zstd yet.
- Registered-folder synchronization is disabled. There is no ownership controller, Git projection, Syncthing admin integration or tsnet/WireGuard connectivity. These must not be advertised as working.

Implementation references checked: [Go os.Root](https://pkg.go.dev/os#Root), [Go TLS configuration](https://pkg.go.dev/crypto/tls#Config), [Android foreground-service types](https://developer.android.com/develop/background-work/services/fgs/service-types), [Android Storage Access Framework](https://developer.android.com/guide/topics/providers/document-provider).
