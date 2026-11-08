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
2. Pod Security Admission is applied per namespace, scoped to what the repo
   controls. The namespaces whose workloads this repo owns and has hardened
   (`linkding`, `cloudflare`, `renovate`) carry `warn` and `audit` at `latest`
   plus `enforce: restricted` with `enforce-version` pinned to the cluster minor
   (`v1.35`). Namespaces running third-party Helm charts (`traefik`,
   `monitoring`) carry `warn` and `audit` only, because those charts include
   components that legitimately need host access — `node-exporter` runs with
   `hostNetwork`/`hostPID` — and enforcing `restricted` would reject them. PSA
   emits no metrics and no Kubernetes Events, so Prometheus cannot surface
   violations; `enforce` is the runtime contract and CI surfaces violations
   before they land. Pinning `enforce-version` keeps a Kubernetes upgrade from
   silently changing what is rejected.
3. Network segmentation is targeted, not a full mesh. Three policies apply,
   in the base tier next to their workloads:
   - `cloudflare` gets a default-deny **egress** policy allowing only DNS,
     the Traefik namespace (the tunnel forwards published hostnames through
     it), and the Cloudflare edge on UDP/7844 and TCP/443. Ingress is left
     unrestricted: cloudflared serves only its health and metrics ports and
     never receives application traffic, and default-denying ingress would risk
     kubelet probe traffic under k3s's network-policy controller for no gain.
   - `linkding` gets a default-deny **ingress** policy allowing only the
     Traefik namespace on TCP/9090, and an **egress** policy allowing DNS and
     external TCP/80 and 443 while excluding the pod, service, link-local, and
     loopback CIDRs. The exclusions bound its server-side fetch (SSRF) surface
     to the public internet; it cannot reach other pods, ClusterIPs, the API
     server, or the cloud metadata endpoint.
   - `renovate` gets a default-deny **egress** policy allowing DNS and external
     TCP/443 with the same exclusions. Renovate holds the App private key
     (ADR-0004), so the policy bounds its east-west reach and non-443 egress.
     It is deliberately not an exfiltration firewall: `0.0.0.0/0` on 443 stays
     because Renovate's datasources are many and FQDN matching is unavailable.
   Cross-namespace rules select the `traefik` namespace by its
   `kubernetes.io/metadata.name` label rather than a chart pod label, so they
   do not depend on chart-specific labels. Egress rules are coarse: vanilla
   `NetworkPolicy` matches IP/port/namespace/pod, not DNS names, and there is no
   Cilium, so "allow `github.com`" is not expressible.
4. PRs are gated by CI: `kubectl kustomize` renders every path a Flux
   Kustomization reconciles, and `kubeconform` validates the rendered objects
   against published schemas (`-ignore-missing-schemas`, since the CRDs have no
   public schema). `kubectl apply --dry-run=server` is not used: it needs a live
   API server, which a hosted runner does not have, so PSA violations surface at
   admission (Consequence 2), not at PR time. The one action used is pinned by
   full commit SHA, and both pinned binaries are verified against their
   published checksums before use.
5. No admission controller (Kyverno/Gatekeeper) is added now. `pinDigests` +
   PR review + PSA `restricted` + the CI gate cover the gaps the review found;
   an admission webhook is itself a privileged, token-bearing component sitting
   in the admission critical path.

## Consequences

1. Finding 1 is addressed for the workloads that carry a credential or face the
   internet (`cloudflared`, `linkding`, `renovate`); `traefik` and `monitoring`
   remain unsegmented (Deferred #4). Findings 2 and 3 are addressed, and finding
   4 gains its validation gate. ADR-0001 Deferred #4 (cloudflared unhardened)
   closes; Deferred #2 and #3 are partly addressed.
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
6. Two staging behaviours are assumed, not verified from this repo: that
   k3s's kube-router evaluates egress **post-DNAT** (so the DNS-by-identity
   rules hold), and that `cloudflared` tolerates `readOnlyRootFilesystem`. Run
   both checks in staging before relying on them.

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
4. Segmentation for the third-party chart namespaces (`traefik`,
   `monitoring`), which run components that legitimately need host access.
