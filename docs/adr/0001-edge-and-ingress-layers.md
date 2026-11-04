# 0001. Layered edge: Cloudflare Tunnel in front of Traefik

Status: accepted (staging)
Date: 2026-11-04

## Context

The cluster has no public ingress address: Traefik runs with a `ClusterIP`
Service and the only way in is the `linkding-pith` Cloudflare Tunnel. The
cluster is a learning homelab that will grow to several apps plus a self-hosted
public website. "Ingress" was being conflated across three layers, and a
Grafana Ingress was being wired through the HelmRelease's `valuesFrom`, which
cannot carry a TLS Secret.

## Decision

1. Cloudflare Tunnel is the edge/connectivity layer. It is outbound-only, so no
   inbound ports are open and the origin IP stays hidden.
2. Traefik (`infra/base/controllers/traefik`) is the single in-cluster L7
   router. The tunnel forwards each published hostname to Traefik, which routes
   by `Host` to the right Service.
3. Identity/policy is its own layer and is not Traefik's job. Private apps get a
   Cloudflare Access policy; the public website does not.
4. Manifests are split by tier in both base and env:
   `<area>/base/<tier>/<component>` holds reusable manifests and
   `<area>/<env>/<tier>/<component>` holds environment ones, so the controllers
   and configs roots are `./<area>/<env>/controllers` and
   `./<area>/<env>/configs`.
5. The tunnel is shared edge infrastructure, so it lives in `infra/configs`
   (namespace `cloudflare`), not under an app.

## Consequences

1. Adding an app means an Ingress plus a Cloudflare DNS record, and a Cloudflare
   Access policy if the app is private. The tunnel config changes only to add a
   published hostname.
2. TLS terminates at Cloudflare's edge, so tunnel-served hosts need no
   in-cluster certificate.
3. Cloudflare is in the trust path: it sees decrypted traffic, and the CF
   account can publish the cluster. MFA on the account; the tunnel credentials
   are a root credential and stay age-encrypted.
4. Prometheus, Alertmanager, and the Kubernetes API are never published.

## Rejected

1. Chart-native `grafana.ingress` values in `base/controllers` — leaks
   environment hostnames into base.
2. Injecting a Secret name for TLS through `valuesFrom` — `valuesKey` is a data
   key, not a path into values, and a certificate is consumed by the Ingress as
   a `kubernetes.io/tls` Secret, not merged through values.
3. Running a second ingress controller alongside Traefik.
4. Publishing private tools with only the app's own login and no identity gate.

## Deferred

1. An age-encrypted TLS Secret is only needed if TLS is terminated in-cluster
   (direct/LAN access or origin TLS). Not needed on the tunnel path.
2. Cloudflare Access policies are configured in Cloudflare, not in this repo.
