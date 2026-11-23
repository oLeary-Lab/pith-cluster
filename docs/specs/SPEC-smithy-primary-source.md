# Spec: Smithy (Forgejo) as primary self-hosted source control (staged slice)

Status: draft (awaiting approval)
Date: 2026-11-23
Companion decision record: ADR-0005 (to be written before implementation)

## Naming

The deployed service is **Smithy**; the software it runs is **Forgejo**. The
instance name `smithy` applies to the Kubernetes objects, the namespace, the
directories, the Secrets, and the published hostname `smithy.olearylab.com`.
"Forgejo" remains the name of the image, the upstream project, and its CLI
(e.g. `forgejo dump`). The abandoned scaffold that previously sat untracked at
`apps/base/forgejo` and `apps/staging/forgejo` has been deleted; the app is built
at `apps/base/smithy` and `apps/staging/smithy`.

## Objective

Run Smithy in the `staging` cluster as the operator's primary self-hosted source
control, hosting `pith-cluster`. GitHub becomes an automatic push-mirror used as
the bootstrap/break-glass path. Smithy's data — git **and** Forgejo-side state
(issues, PRs, users, LFS, attachments) — is backed up off-cluster and a restore is
demonstrated. **Flux continues to pull from GitHub throughout this slice**; its
source is not cut over.

User: the solo operator (today), and the automation loop built on Smithy later
(issue triage → tickets, then self-hosted Actions runners).

Success is not "Smithy is up" — it is "Smithy is the source, GitHub is a mirror
that nothing depends on day-to-day, and a cold start is demonstrably recoverable."

### Scope

In scope:
- Finish and correct the Smithy app (deploy, Service, Ingress, NetworkPolicy,
  secrets, storage sizing, hardening, database backend).
- Publish the hostname through the existing edge and gate it behind Cloudflare
  Access.
- Configure the GitHub **push mirror** of `pith-cluster`.
- Scheduled off-cluster backup of Smithy's data **and** a demonstrated restore.
- Critical rework of the existing on-branch scaffold (see below).
- An ADR-0005 recording the decision, the bootstrap circle, and the DR posture.

Out of scope:
- Cutting Flux's source over to Smithy (`gotk-sync.yaml` unchanged).
- Self-hosted Actions runners.
- Migrating other repositories onto Smithy.
- Retiring or deleting GitHub.
- In-cluster TLS (edge terminates at Cloudflare, per ADR-0001).

## Critical assessment of the existing scaffold (provisional — not authoritative)

The abandoned scaffold was a starting sketch (since deleted). Every claim below
was read from its files; none of it was a given just because it was on disk. Kept
as a record of what not to repeat. Findings, highest first:

1. **CI is red today.** `apps/staging/forgejo/kustomization.yaml` lists
   `forgejo-dotenv.yaml`, which does not exist. `kubectl kustomize` fails, so the
   `validate` workflow fails.
2. **The CI drift gate will also fail.** `.github/workflows/validate.yaml` lists
   reconciliation roots explicitly and fails when a Flux-resolved root is not
   listed (the "drift" check). `./apps/staging` resolves to each child overlay, so
   adding the app's staging overlay requires adding it to that list — otherwise CI
   fails on a missing-root error.
3. **The Pod spec is invalid as written.** The container mounts a `localtime`
   volume that is never declared in `volumes:` → the API server rejects the pod
   (`volumeMounts[].name: Not found`), so the ReplicaSet creates nothing. The
   `# ???` comment confirms it was unresolved.
4. **The data volume path is wrong — confirmed.** The PVC is mounted at
   `/etc/forgejo/data`. The image's own config declares the volume at
   **`/var/lib/gitea`** (`WorkingDir` and `GITEA_WORK_DIR`), with
   `GITEA_APP_INI=/var/lib/gitea/custom/conf/app.ini`. Mounted anywhere else, all
   state lands on the container filesystem and is lost on restart. The image also
   sets `GITEA_TEMP=/tmp/gitea`, so a hardened pod needs a writable `/tmp`.
5. **The namespace violates ADR-0003 §2.** Repo-owned workload namespaces carry
   `enforce: restricted` with `enforce-version` pinned to the cluster minor. The
   scaffold namespace has only `warn`/`audit`, so PSA is inert and hardening is
   convention rather than contract. (`linkding` is the exemplar.)
6. **The image reference is non-conformant, and the wrong *variant*.** The tag
   `:17` exists, but it is a rolling major with no digest, against the canonical
   `tag@sha256:…` form (ADR-0002 §4). More seriously, the non-rootless image sets
   no `USER` (it runs as root), contradicting the repo's `runAsNonRoot`/PSA
   `restricted` posture; the **`-rootless`** variant sets `User=1000:1000`.
   Verified against the registry: `17.0.2` was built 2026-11-18 and fails the
   14-day floor; **`17.0.1-rootless`** (2026-10-26) clears it.
7. **Missing the pieces the exemplar has.** No `service.yaml`, `ingress.yaml`, or
   `networkpolicy.yaml`, all of which `apps/base/linkding` carries. Without a
   Service the Ingress has no backend; without a NetworkPolicy the workload is
   unsegmented (ADR-0003 §3 made linkding the precedent, not the exception).
8. **Storage sizing is not credible.** 1Gi RWO for a "mainstay" forge (git + LFS
   + attachments + issues index) is too small; no `storageClassName` is set
   (inherits the default), and the default is node-local, which is exactly the
   failure mode the backup requirement exists to cover.
9. **`apps` tier naming is consistent with `linkding`** (`apps/base/<component>`,
   `apps/staging/<component>`), so no change is implied — but note it differs from
   the `base/<tier>/<component>` pattern ADR-0001 §4 states for `infra`/`monitoring`
   and ADR-0002 §1 restates. Not a defect here; recorded so it is not mistaken for
   one.
10. **The container port is wrong.** The scaffold exposes `containerPort: 1987`.
   The image exposes **3000/tcp (HTTP)** and **2222/tcp (SSH)**; the Service and
   Ingress must target 3000.

Disposition: the scaffold was **deleted**, not repaired — its value is the
findings above, not the YAML, which is cheap to write correctly at implementation
time. Rebuild from this spec, not from it, so none of these defects return.

## Tech stack

- Cluster: single-tenant k3s; Flannel + k3s embedded kube-router network policy;
  no Cilium, so **no FQDN matcher** (ADR-0003).
- GitOps: Flux v2 (kustomize-controller), SOPS age decryption.
- Edge: Cloudflare Tunnel → Traefik → Service → Pod (ADR-0001). No in-cluster TLS.
- Smithy image: Forgejo from `codeberg.org/forgejo/forgejo`, pinned tag + digest.
- Database backend: **SQLite** for this slice — one stateful component, no separate
  database to back up or keep alive. Migration to Postgres is a recorded future
  path (see Deferred target design).
- Backup: **a rotated, offline USB drive** as the independent copy for this slice,
  written by `restic`. The spare machine (MinIO + Postgres replica) and cloud
  object storage are recorded future legs, not built here.
- Storage: the node is a single **~58 GB eMMC/SD card with ~38 GB free**
  (`/dev/mmcblk1p1`), against ~16 GB RAM. The PVC is sized modestly (target
  ~10 GiB) so it never crowds the shared root filesystem, which also holds
  container images and where kubelet's disk-pressure thresholds live. A 250 GB SSD
  is deferred on capacity **and endurance** grounds (flash wear), to be revisited
  if the registry or LFS lands.
- Toolchain (from `mise.toml`): `kubectl`, `flux2`, `sops`, `helm`, `flate`.
- Policy floor: `minimum_release_age = "14d"` (mise) and `minimumReleaseAge: "14d"`
  (Renovate).

## Commands

```bash
# Toolchain
mise install

# Render a reconciliation root exactly as CI does
kubectl kustomize apps/staging/smithy

# Validate a rendered root (mirrors the CI gate)
kubectl kustomize apps/staging/smithy > /tmp/smithy.yaml
kubeconform -strict -summary -ignore-missing-schemas -skip Secret \
  -kubernetes-version 1.35.0 /tmp/smithy.yaml

# Secrets (SOPS/age; recipient in .sops.yaml)
sops -e -i apps/staging/smithy/smithy-dotenv.yaml    # encrypt in place
sops -d apps/staging/smithy/smithy-dotenv.yaml       # inspect/decrypt

# Reconcile after merge
flux reconcile kustomization apps --with-source

# Re-seed a rebuilt cluster (existing bootstrap path)
scripts/bootstrap.sh
```

## Project structure

```
apps/base/smithy/           # reusable manifests (may be rewritten from scratch)
  namespace.yaml            # PSA restrict + enforce-version pinning (ADR-0003)
  deployment.yaml           # rootless image, probes, hardening, /tmp/gitea emptyDir
  configmap.yaml            # app.ini or GITEA__* env (ROOT_URL, SSH, storage)
  service.yaml              # ClusterIP on 3000 (HTTP; image also exposes 2222/tcp SSH)
  networkpolicy.yaml        # default-deny ingress (Traefik) + egress (DNS, mirror, backup)
  storage.yaml              # PVC mounted at /var/lib/gitea, deliberately small
  kustomization.yaml        # resource list (must match the files present)
apps/staging/smithy/        # environment overlay
  ingress.yaml              # host: smithy.olearylab.com, ingressClassName: traefik
  smithy-dotenv.yaml        # SOPS-encrypted Secret (env for the pod)
  mirror-credential.yaml    # SOPS-encrypted Secret/DeployKey for the push mirror
  backup-dotenv.yaml        # SOPS-encrypted credentials for the backup target
  backup-cronjob.yaml       # scheduled off-cluster backup (Renovate CronJob exemplar)
  kustomization.yaml
infra/base/configs/cloudflared/config.yaml   # add published hostname (tunnel allowlist)
.github/workflows/validate.yaml              # add apps/staging/smithy to `roots`
docs/adr/0005-<slug>.md                      # decision record
docs/specs/SPEC-smithy-primary-source.md    # this file
```

Note the `infra/base/configs/cloudflared/config.yaml` edit is in the **`infra`**
area, not `apps`; it is a cross-cutting change and belongs in the same change set.

## Code style

Follow the existing exemplars; new code should be indistinguishable from what is
already there. The Linkding NetworkPolicy is the reference for tone and precision
(explanatory comments stating *why* a rule is bounded, not what it does):

```yaml
  # Only Traefik, the sole in-cluster path to the app. ...
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
```

Conventions:
- Cross-namespace selectors use `kubernetes.io/metadata.name`, never chart labels.
- Images are `tag@sha256:…`; never a bare tag or a digest-only reference.
- Secrets are SOPS-encrypted; only `data`/`stringData` are encrypted (`.sops.yaml`)
  and the `sops:` block is stripped by Flux on decryption.
- Namespaces this repo owns carry `enforce: restricted` + `enforce-version: v1.35`.
- Comments explain constraints and rejected alternatives, not restate the field.

## Testing strategy

There is no unit-test layer in this repo; "tests" are the CI gate and empirical
staging verification.

- **CI (must pass, and must cover the new root):** `validate.yaml` renders each
  reconciliation root with `kubectl kustomize` and validates with `kubeconform`;
  `apps/staging/smithy` is added to `roots`, and the drift assertion must pass.
  Secrets are skipped (kustomize cannot decrypt in CI).
- **Convergence (empirical, staging):** Flux `apps` Kustomization Ready; pod
  Running and Ready; PSA `restricted` enforcement accepts the pod (ADR-0003 §2).
- **Reachability (empirical, staging):** `smithy.olearylab.com` resolves through
  the tunnel, Traefik routes by Host, Cloudflare Access denies an unauthenticated
  request at the edge.
- **Mirror round-trip:** a commit pushed to Smithy appears on GitHub without
  manual action; SHAs match.
- **Restore drill:** a backup is restored into a scratch location and compared
  against the pre-loss state (git history, issues/PRs, users, LFS/attachments).
  The drill is timed; the measured duration is the real RTO.
- **Secret hygiene:** a grep confirms no plaintext secret is committed.

Coverage expectation: every reconciliation root the Flux Kustomizations declare is
in the CI roots list; no tier is unvalidated.

## Boundaries

- **Always**
  - Pin images as `tag@sha256:…`.
  - SOPS-encrypt every secret; never commit plaintext.
  - Give owned namespaces `enforce: restricted` with a pinned `enforce-version`.
  - Add the app's staging overlay to the CI `roots` list in the same change.
  - Ship a default-deny NetworkPolicy pairing (ingress from Traefik; egress for
    DNS, the mirror, and the backup target).
  - Keep the render → validate path green before merging.
- **Ask first**
  - Adding an external credential (GitHub mirror, backup target).
  - Changing Cloudflare DNS, tunnel hostname allowlist, or Access policy.
  - Changing StorageClass or volume size, or introducing a new storage dependency.
  - Adding a tool to `mise.toml`/CI, or bumping a toolchain version.
  - Any change to `gotk-sync.yaml` or the Flux source.
- **Never**
  - Commit plaintext secrets.
  - Publish the hostname before its Cloudflare Access policy exists (ADR-0001 §3).
  - Cut Flux's source over to Smithy (out of scope for this slice).
  - Weaken or disable a CI check to get green.
  - Use an unpinned image, or a registry/tag Renovate cannot age-gate without an
    ADR recording the exception (ADR-0002 §4, Deferred #2).
  - Publish `2222/tcp`, or mirror a repository not intended to be public.

## Hardening (application-level)

Network admission and application authorization are different layers, and both are
required: Cloudflare Access decides whether a request reaches Smithy at all;
Forgejo decides what the caller may then do. Neither substitutes for the other
(ADR-0001 §5 records that in-cluster callers bypass the edge entirely).

- **Access is scoped to the operator's identity alone, deny-by-default**, and is
  live before the hostname is published. Implement it as a **reusable Cloudflare
  Access Group**, not an inline email list, so adding the 1–3 developers who may
  follow is a group edit rather than a policy rewrite. MFA is enforced at the
  identity provider, not only inside Smithy.
- **Self-registration is disabled** — account creation stays deliberate even once
  other developers exist.
- **TOTP 2FA is required** for accounts (verify the exact per-version setting).
- **`2222/tcp` is never published.** Git over HTTPS through Access; SSH git would
  need its own path and client-side `cloudflared access`, decided later.
- **Only public-intended repositories are mirrored**; a push mirror to a public
  GitHub repository publishes everything it carries.
- **The mirror deploy key is push-only and scoped to the one repository**, and
  stays SOPS-encrypted.

When other developers arrive, the work splits in two: their identities join the
Access group (admission), and Forgejo's org/team roles grant what they may do
(authorization). Multi-user also implies an identity provider and an audit trail;
both are future work, not this slice.

## Success criteria

1. `kubectl kustomize apps/staging/smithy` renders clean, and the `validate`
   workflow passes with `apps/staging/smithy` present in `roots` and no drift
   error.
2. Flux reports the `apps` Kustomization Ready; the Smithy pod is Running and
   Ready, and was **accepted** by PSA `restricted` enforcement.
3. `smithy.olearylab.com` is reachable through the tunnel and Traefik, and an
   unauthenticated request is denied by Cloudflare Access.
4. `pith-cluster` exists in Smithy with full history; a push to Smithy appears on
   the GitHub mirror with no manual step, and the SHAs match at a point in time.
5. A fresh clone of `pith-cluster` from Smithy matches the GitHub copy.
6. The backup job runs green on schedule, and a **restore drill** reconstructs
   Smithy (git history + issues/PRs + users + LFS/attachments) into a scratch
   location matching the pre-loss state. The drill is written down and timed.
7. No plaintext secret is present in the repository.
8. The PVC is sized deliberately (target ~10 GiB) against the node's ~38 GB free
   space, with the measurement and the resulting headroom recorded.
9. ADR-0005 exists, accepted, before any implementation merge.

## Deferred target design (recorded, not built here)

Direction: Smithy migrates from SQLite to Postgres, and a spare machine outside
the cluster becomes the homelab's standby and backup host. Recorded so this slice
does not foreclose it; the machine is not ready, so none of it is built now.
Precedent for record-then-adopt: ADR-0002 Deferred #1 (GitHub App) was adopted
later as ADR-0004.

Proposed shape:
- Postgres primary in-cluster alongside Smithy; a streaming replica on the spare
  machine. The bridge from today is a **migration**, not just "add Postgres":
  Forgejo's dump/restore moves SQLite → Postgres and must be rehearsed once.
- The replica is **not** a backup: pair it with periodic snapshots into a MinIO
  bucket on the spare machine for point-in-time safety, keeping the offline USB as
  the independent leg.
- MinIO on the spare machine as the shared S3-compatible target for Smithy and
  future apps — and possibly as Smithy's blob store: LFS, attachments, avatars,
  and archives can live in object storage instead of growing the node disk.
- A **third machine** is the eventual home for self-hosted runners. As CI/CD lands,
  Smithy's built-in **OCI/container registry** becomes the image store for those
  builds (verify version support). Registry blobs are the real volume driver, and
  they belong in object storage, not the node disk.
- Cloud object storage (R2/B2/S3) optional, for an immutable offsite copy; its
  egress cost is paid only on a severe DR.

Decided: the Postgres primary is **in-cluster**, alongside Smithy; the spare
machine holds the **replica** as a standby/copy and is never a runtime
dependency. The deferred work needs its own spec when the machines exist.

Risks to resolve before building:
- **Cross-machine reachability:** the spare and runner machines sit outside the
  cluster, and Traefik is reachable only through the Cloudflare tunnel
  (ADR-0001). How Postgres replication, MinIO access, and runner/registry traffic
  cross that boundary is unresolved and must be designed before the slice.
- **Correlated failure:** MinIO and the replica on one machine weakens copy
  independence — the USB leg (and later the cloud leg) is what preserves it.
- **Recursive backup:** the backup host must itself be backed up, or it becomes a
  single point of total loss.
- **Unproven replica:** a standby that is never promoted is theatre; the design
  needs a failover rehearsal or its RTO benefit is imaginary.

## Decisions taken

- **Mirror credential:** a repository-scoped **deploy key with write access**
  (push-only), SOPS-encrypted — least privilege, no PAT to rotate.
- **Image:** `codeberg.org/forgejo/forgejo:17.0.1-rootless@sha256:5ef02fbcf22beef56b8c844952ffad58cfe177b6f98e46e6abb5df90b88dc8d3`.
  codeberg.org is the only official source.
- **Interim copy count:** one USB drive is **two copies**. Recorded honestly as a
  2-copy posture; true 3-2-1 needs a second off-site drive or an early cloud leg.
- **Cloudflare Access:** configured by the operator (outside the repo); the
  hostname is not published until the policy exists (ADR-0001 §3).
- **Retention:** 30 daily / 12 monthly.

## Open questions

1. **Data volume.** Starting posture is code, issues, and config only. The future
   volume driver is the OCI/container registry once CI/CD lands, not source code.
   Node measured: ~38 GB free of ~58 GB.
2. **Flash durability.** The node's storage is an eMMC/SD card, which wears out
   and can fail suddenly; the 250 GB SSD is deferred on capacity and endurance
   grounds. Decide when, or whether, that changes.
3. **Spare machine disk.** Its capacity is unknown; the Postgres replica plus MinIO
   snapshots must fit, and the backup host must itself be backed up. Establish its
   disk budget before the deferred slice.
4. **Age-gating verification.** Confirm whether Renovate's docker datasource
   consumes the registry's `created` timestamp for codeberg; if not, the ADR
   exception stands.
5. **Registry (future).** Smithy's built-in OCI/container registry will hold build
   images once CI/CD lands; confirm Forgejo's version supports it, that its blobs
   can be backed by object storage rather than the node disk, and that image
   retention/GC exists — a registry without pruning grows without bound.
