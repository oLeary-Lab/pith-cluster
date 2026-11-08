# 0001. Layered edge: Cloudflare Tunnel in front of Traefik

Status: accepted (staging)
Date: 2026-11-04

## Context

The cluster has no public ingress address: Traefik runs with a `ClusterIP`
Service and the only way in is the `pith-cluster` Cloudflare Tunnel. The
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
3. Identity/policy is its own layer and is not Traefik's job. Publishing a
   private app is gated on its Cloudflare Access policy existing first; the
   public website has no Access policy. Access lives in Cloudflare, not here, so
   the gate is a prerequisite checked before a hostname is added to the tunnel.
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
5. Access is an edge-only boundary. Any in-cluster caller (a pod, `kubectl
   port-forward`, or an exec session) can reach a published route by sending
   `Host: grafana.olearylab.com` to the Traefik Service, and nothing in the
   cluster authenticates it. `trustedIPs: 10.42.0.0/16` additionally lets any
   pod spoof `X-Forwarded-For` into the access log. Expected on a homelab;
   recorded so "private apps get Access" is not mistaken for an authorization
   boundary.
6. Grafana is published on the tunnel allowlist only behind a Cloudflare Access
   policy; the Ingress without that policy would expose it directly. The policy
   lives in Cloudflare and cannot be seen from this repo, so publishing a
   private hostname requires confirming the Access policy exists as a manual
   step before the hostname is added to the tunnel; the Ingress and the tunnel
   allowlist entry are the in-repo halves of that gate.
7. Cutover: for a short window the new connector forwards to Traefik before the
   linkding Ingress reconciles, so `linkding.olearylab.com` can return
   intermittent 404s.

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
3. The edge is unmonitored: `metrics: 0.0.0.0:2000` has no Service or
   ServiceMonitor, so a tunnel outage is invisible to the monitoring stack. Add
   a Service on 2000, a ServiceMonitor, and an alert on
   `cloudflared_tunnel_ha_connections == 0`.
4. The connector is otherwise unhardened: no `resources`, no `securityContext`,
   no NetworkPolicy. The `/ready`-as-liveness bug is fixed in this change; the
   rest is out of scope here.
