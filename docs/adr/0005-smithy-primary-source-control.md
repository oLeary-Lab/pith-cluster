# 0005. Smithy (Forgejo) as primary source control, GitHub as mirror

Status: proposed
Date: 2026-11-23

Companion spec: `docs/specs/SPEC-smithy-primary-source.md`

## Context

GitHub is the only source of truth for this cluster. Flux reconciles `main` from
`ssh://git@github.com/oLeary-Lab/pith-cluster` (`clusters/staging/flux-system/gotk-sync.yaml`),
and `scripts/bootstrap.sh` re-seeds a rebuilt cluster with `flux bootstrap github`,
managing the deploy key and committing that state outside PR review.

The goal is the opposite arrangement: a self-hosted forge becomes the source, and
GitHub is demoted to a mirror that nothing depends on day to day.

That arrangement has a structural hazard, and it should be stated plainly rather
than discovered later. The repository that defines a service cannot be stored
*only* inside the service it defines: if Forgejo's storage is lost, Flux has no
source to pull to recreate Forgejo. This is the bootstrap circle. It is survivable
while GitHub remains the machine's source — a Forgejo outage is then a
non-event, because Flux keeps its last-applied state and nothing external
depends on GitHub being absent. It becomes load-bearing the moment Flux's source
is cut over.

Conventions the change must fit, established before it:

1. Tiers are split `base`/`<env>`; a component is `<area>/base/<component>` with
   its environment overlay at `<area>/<env>/<component>` (ADR-0001 §4, ADR-0002 §1).
2. Namespaces this repo owns carry Pod Security Admission `enforce: restricted`
   with `enforce-version` pinned to the cluster minor, and
   credential-bearing/internet-facing workloads get a default-deny NetworkPolicy
   pairing (ADR-0003).
3. Workload images are pinned `tag@sha256:…` and held to a 14-day release-age
   floor (ADR-0002 §4).
4. Secrets are SOPS/age encrypted; only `data`/`stringData` are encrypted.
5. The edge is the Cloudflare Tunnel in front of Traefik, and publishing a private
   hostname is gated on its Cloudflare Access policy existing first (ADR-0001 §3).
6. PRs are gated by `kubectl kustomize` + `kubeconform` over an explicit list of
   reconciliation roots, with a drift assertion against the Flux `spec.path`
   values (ADR-0003 §4).

An earlier scaffold for this component was written off-repo and reviewed. Its
defects (wrong data path, wrong port, wrong image variant, a mount for an
undeclared volume, PSA absent) are recorded in the companion spec. It was deleted
rather than repaired; the findings, not the YAML, were the useful output.

## Decision

1. **Run Forgejo in-cluster as `Smithy`**: manifests at `apps/base/smithy` with the
   overlay at `apps/staging/smithy`, namespace `smithy`. "Smithy" names the
   instance (namespace, objects, Secrets, hostname); Forgejo remains the name of
   the software, the image, and its CLI. The namespace carries PSA
   `enforce: restricted` at `enforce-version: v1.35` (ADR-0003 §2).
2. **Pin the rootless image from codeberg.org**:
   `codeberg.org/forgejo/forgejo:17.0.1-rootless@sha256:5ef02fbcf22beef56b8c844952ffad58cfe177b6f98e46e6abb5df90b88dc8d3`.
   The `-rootless` variant sets `User=1000:1000`; the default image sets no `USER`
   and runs as root, which the hardening posture rejects. `17.0.2` was built
   2026-11-18 and fails the 14-day floor; `17.0.1` (2026-10-26) clears it.
   codeberg.org is the only official source — Docker Hub's `forgejo/forgejo` is an
   empty 2022 placeholder and everything else there is an unofficial mirror.
3. **Use SQLite for this slice.** One stateful component, self-contained in the
   data directory that the backup already captures. Postgres is a recorded future
   migration, not a now-decision.
4. **GitHub becomes a push mirror of `pith-cluster`** via a repository-scoped
   deploy key with write access, SOPS-encrypted. **Flux keeps pulling from
   GitHub.** The source cutover is deliberately a separate, reversible step.
5. **Publish `smithy.olearylab.com`** through the existing tunnel and a Traefik
   Ingress, behind a Cloudflare Access policy that must exist before the hostname
   is added to the tunnel allowlist (ADR-0001 §3). No in-cluster TLS.
6. **Back up with `restic` to a rotated, offline USB drive**, restoring the whole
   `/var/lib/gitea` tree (git, issues, users, LFS, attachments), and **drill a
   restore**, because an untested backup is not one.
7. **Observe the image's own layout**: the PVC mounts at `/var/lib/gitea`
   (`WorkingDir`/`GITEA_WORK_DIR`), the Service targets **3000** (the image also
   exposes `2222/tcp` for SSH), and `/tmp` is a writable `emptyDir` because
   `GITEA_TEMP=/tmp/gitea`.
8. **Extend the CI gate** by adding `apps/staging/smithy` to the `roots` list in
   `.github/workflows/validate.yaml`.
9. **Record the target architecture, build none of it**: Postgres primary
   in-cluster with a streaming replica on a spare machine, MinIO as a shared
   object store, an eventual OCI registry and runner machine. This ADR's Deferred
   section is the pointer; the design needs its own spec when the machines exist.

## Consequences

1. GitHub stays the machine's source, so this slice carries **no DR regression** —
   the cluster can still be rebuilt from GitHub alone. Smithy becomes a *second*
   place truth lives, which is the point and also the new responsibility.
2. Two new external credentials are now held by the cluster (mirror deploy key,
   backup target); both stay SOPS-encrypted and scoped to their single job.
3. The interim posture is **two copies** (PVC + USB), recorded honestly rather than
   described as 3-2-1. A second off-site drive or an early cloud leg closes the gap.
4. The node's storage is a single **~58 GB eMMC/SD card with ~38 GB free**, so the
   PVC is sized modestly (target ~10 GiB) and the root filesystem is shared with
   container images and kubelet's disk-pressure thresholds. Flash wear is a real
   failure mode; the backup does the load-bearing work.
5. The tunnel allowlist and the CI roots list each gain an entry, and the Access
   policy becomes a prerequisite for publishing the hostname.
6. Smithy's namespace is PSA-enforced and segmented; the NetworkPolicy opens egress
   only for DNS, the GitHub mirror, and the backup target.
7. Whether Renovate can age-gate a `codeberg.org` image is **unverified**. ADR-0002
   Deferred #2 records the Docker Hub-only timestamp limitation for GHCR; if it
   extends to codeberg, the 14-day floor on this image is a manual discipline and
   the exception belongs in this record.
8. **Access is scoped to the operator's identity alone for now**, implemented as a
   reusable Access Group so the 1–3 developers who may follow are a group edit, not
   a policy rewrite. Network admission (Cloudflare Access) and application
   authorization (Forgejo org/team roles) are separate layers; multi-user also
   implies an identity provider and an audit trail.

## Rejected

1. **Cutting Flux's source over to Smithy in the same change.** It puts the
   irreversible move and the thing it depends on in one step, and it converts a
   survivable Forgejo outage into a bootstrap-circle problem before the mirror and
   backups have been proven. Staged, reversible, verified first.
2. **Postgres now.** A second stateful workload with its own PVC, credentials,
   backup path, and failure mode, for a load SQLite serves comfortably at one
   operator. Same shape as ADR-0003's rejected Kyverno and full network mesh.
3. **In-cluster MinIO as a backup target.** Backups inside the cluster share fate
   with it: if the node or cluster is lost, so are the backups. Independent
   storage means a different machine or an offline medium.
4. **The unofficial Docker Hub images, or the non-rootless variant.** Both are
   avoidable trust or hardening regressions; the official rootless image is
   pinnable and already non-root.
5. **Putting the database on the spare machine.** It makes source control depend on
   infrastructure outside the cluster, which the cluster cannot declare or
   reconcile — the external-dependency shape ADR-0001 treats Cloudflare as.
6. **Adding the 250 GB SSD now.** The node has ~38 GB free, far from kubelet's
   thresholds, and the workload is deliberately small. Revisit on measurement, not
   precaution.
7. **Proton Drive as the automated backup target.** Built for human sync, not
   server backups; only viable as a manual copy of an already-encrypted repository.

## Deferred

1. **The Flux source cutover** to Smithy, as its own verified step.
2. **SQLite → Postgres migration** and a streaming replica on the spare machine,
   with periodic snapshots into MinIO (the replica is not itself a backup).
3. **MinIO on the spare machine**, and an optional cloud leg (R2/B2/S3) for an
   immutable off-site copy.
4. **The OCI/container registry** for build images, with object-storage-backed
   blobs and a retention/GC story.
5. **Self-hosted runners on a third machine**, and the design of how machines
   outside the cluster reach in-cluster services given the tunnel-only edge.
6. **The 250 GB node SSD**, on capacity and flash-endurance grounds.
7. **Age-gating verification** for the codeberg.org image (see Consequences 7).
8. **Multi-user**: an identity provider, Forgejo orgs/teams for authorization, and
   an audit trail, before granting the 1–3 developers who may follow.
