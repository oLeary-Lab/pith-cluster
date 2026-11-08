# 0003. Workload hardening, Pod Security Admission, and targeted network segmentation

Status: accepted (staging)
Date: 2026-11-08

## Context

A posture assessment of `main` (`tmp/security-posture-main.md`, 2026-11-08) found
the cluster has no `NetworkPolicy` outside Flux's own manifests, that the
credential-bearing and internet-exposed workloads are unhardened, that no app
namespace enforces Pod Security Admission (PSA), and that the delivery path has
no validation gate. It ranked network segmentation first.

Facts that shape the response:

- The cluster is single-tenant k3s with Flannel and k3s's embedded kube-router
  network-policy controller. Enforcement was verified empirically on 2026-11-08:
  a default-deny ingress policy blocked pod-to-pod traffic and an allow rule
  restored it. There is no Cilium, so there is no DNS-name (`toFQDNs`) matcher
  available.
- The Renovate CronJob already satisfies the PSA `restricted` profile and is the
  reference shape for the other workloads.
- App namespaces carry no PSA labels, so PSA is present but inert; the default
  for every mode is `privileged`.
- There is no `.github/` and no CI. Flux reconciles `main` with `prune: true`,
  so the only gate on a manifest reaching the cluster is branch protection.

## Decision

1. Every credential-bearing or internet-exposed workload meets the PSA
   `restricted` profile: an explicit `runAsNonRoot: true` (`runAsUser: 82` alone
   does not satisfy it), `allowPrivilegeEscalation: false`,
   `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`,
   `readOnlyRootFilesystem` where the image tolerates it (with a writable volume
   for data paths where it does not), `automountServiceAccountToken: false` on
   pods that never call the API, and resource requests/limits. Applied now to
   `cloudflared` and `linkding`; the Renovate pod is already compliant.
2. App namespaces carry PSA labels: `warn` and `audit` at `latest` first, then
   `enforce: restricted` with `enforce-version` pinned to the running cluster's
   minor. PSA emits no metrics and no Kubernetes Events, so Prometheus cannot
   surface violations; `enforce` is the runtime contract and CI surfaces
   violations before they land. Pinning `enforce-version` keeps a Kubernetes
   upgrade from silently changing what is rejected.
3. Network segmentation is targeted, not a full mesh. Default-deny applies where
   a root credential lives — `cloudflare` (ingress from Traefik only; egress to
   DNS and the Cloudflare edge on UDP/7844 and TCP/443) — and to `linkding`'s
   ingress (from Traefik). Egress rules are documented as coarse: vanilla
   `NetworkPolicy` matches IP/port/namespace/pod, not DNS names, and there is no
   Cilium, so "allow `github.com`" is not expressible and a full mesh would be
   mostly unenforceable intent.
4. PRs are gated by CI: `kubectl kustomize` over the three roots, `kubeconform`
   schema validation, and `kubectl apply --dry-run=server` to surface PSA `warn`
   output. Actions are pinned by full commit SHA.
5. No admission controller (Kyverno/Gatekeeper) is added now. `pinDigests` +
   PR review + PSA `restricted` + the CI gate cover the gaps the review found;
   an admission webhook is itself a privileged, token-bearing component sitting
   in the admission critical path.

## Consequences

1. Findings 1, 2 and 3 are addressed, and finding 4 gains its validation gate.
   ADR-0001 Deferred #4 (cloudflared unhardened) closes; Deferred #2 and #3 are
   partly addressed.
2. Once `enforce: restricted` lands, a violating manifest is rejected at
   admission, so the workloads' hygiene becomes a contract rather than a
   convention.
3. Egress remains coarse by design. The limitation is recorded here so
   "default-deny" is not mistaken for an exfiltration firewall.
4. CI introduces GitHub as a dependency for PR validation. A push directly to
   `main` (bootstrap, admin) still bypasses it, so branch protection remains the
   outer control.
5. Adding `kubeconform` to the toolchain must respect the repo's 14-day
   release-age floor; a pinned container or SHA-pinned action is preferred over
   an unpinned install.

## Rejected

1. **A full per-namespace mesh now.** With no FQDN matcher and no Cilium, egress
   rules collapse to "world on 443/53," which buys little of the claimed benefit
   for a single tenant. Revisit when a second tenant or a genuinely sensitive
   workload appears.
2. **`enforce-version: latest`.** A cluster upgrade could start rejecting pods
   with no repo change. Pin to the cluster minor and bump deliberately.
3. **Kyverno/Gatekeeper now.** Overkill at one tenant, and a new privileged
   component to harden. Adopt at the first policy PSA cannot express, or the
   first second contributor.
4. **Relying on Prometheus/Alertmanager for PSA violations.** PSA emits neither
   metrics nor Events; surfacing them needs a log pipeline and apiserver audit
   logging.

## Deferred

1. FQDN-scoped egress — Cilium `toFQDNs` or an egress proxy — if the coarse
   allowlist proves insufficient.
2. An admission controller for digest/signature enforcement (`cosign verify`) at
   multi-tenant scale.
3. A log pipeline for the Traefik access logs and, if wanted, PSA audit
   (ADR-0001 Deferred #3).
4. Full-mesh segmentation for the namespaces that carry no root credential.
