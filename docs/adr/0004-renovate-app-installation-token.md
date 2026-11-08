# 0004. Renovate credentials via a GitHub App installation token

Status: accepted (staging)
Date: 2026-11-08

## Context

ADR-0002 §7 stored a fine-grained GitHub PAT, scoped to only
`oLeary-Lab/pith-cluster` with `Contents`, `Issues`, `Pull requests` and
`Commit statuses` write, SOPS-encrypted as the Secret `renovate-dotenv` and
mounted into the in-cluster Renovate CronJob. The posture assessment
(`tmp/security-posture-main.md`, finding 6) and ADR-0002's own Deferred #1 and
#3 flagged that this is a durable repo-write credential whose only protection is
a fixed expiry with no leading renewal signal.

The cluster reconciles `main` with `prune: true` through Flux, so a repo-write
credential held by a pod is one hop from cluster change; the review lists it
among the assets worth stealing. ADR-0002 Deferred #1 sketched a GitHub App and
set it aside as "another pinned image and key management" for a single-repo
homelab. That tradeoff is reversed here: the cost of a static repo-write token
inside the cluster outweighs the cost of the extra component.

A migration to a self-hosted forge (Forgejo) is anticipated. The mechanism is
chosen so its *shape* — an app plus a short-lived token minted at runtime —
transfers, even though the GitHub App itself does not.

## Decision

1. Replace the fine-grained PAT with a **GitHub App** installed on
   `oLeary-Lab/pith-cluster`. Renovate authenticates with a **short-lived
   installation access token** (about one hour) minted at job start, not a
   static secret.
2. The CronJob gains an **init container** that mints the token: it signs an
   RS256 JWT with the App's private key, exchanges it at the GitHub App API for
   an installation access token, and writes the token to an in-memory
   `emptyDir`. The Renovate container reads the token from that file at startup.
3. The **App private key** is the only stored credential. It stays
   SOPS-encrypted in `infra/staging/configs/renovate/` (the tier that already
   decrypts), is mounted read-only, and the pod remains `restricted`-hardened.
   The App is granted the minimum permissions Renovate needs — the same set the
   PAT carried — scoped to the single installation.
4. The App ID and installation ID are non-secret and live in the ConfigMap with
   the existing `RENOVATE_*` settings. The private key and any minted token are
   never written to a ConfigMap or the working tree.
5. `renovate-dotenv` no longer carries `RENOVATE_TOKEN`; it holds only the App
   private key. The init-container and Renovate images are pinned by
   `tag@sha256`, under the same age floor.

## Consequences

1. The cluster no longer holds a static repository-write token. A stolen pod
   yields at most a ~1h token bounded by the App's permissions rather than a
   durable PAT. ADR-0002 Deferred #3 (PAT rotation) is resolved — expiry is
   automatic.
2. ADR-0002 §7's credential model is superseded by this decision; the rest of
   ADR-0002 stands.
3. The App private key is itself long-lived and powerful — it can mint tokens
   for the installation — so SOPS-at-rest and the `restricted` pod hardening
   stay load-bearing. The blast radius shifts from "a token usable directly" to
   "a key that must be signed with and exchanged."
4. Adds one pinned init-container image and one Secret; the CronJob grows. This
   is the component ADR-0002 Deferred #1 declined, accepted here as the cost of
   removing the static token.
5. On Forgejo migration the App is rebuilt as a Forgejo app/token flow. The
   mint-at-start shape is preserved, so the cost is a new issuer, not a
   redesign.

## Rejected

1. **Keep the PAT and add only a rotation reminder.** Cheaper, but leaves a
   durable repo-write credential in the cluster and depends on a human noticing
   an expiry email.
2. **Move Renovate to GitHub Actions.** Removes the credential from the cluster
   but is GitHub-locked and would be discarded at Forgejo migration.
3. **A pre-minted token refreshed by a sidecar.** The token still has to be
   minted from the private key somewhere; an init container at job start is
   simpler for a daily, short-lived CronJob.
4. **Store a long-lived installation token instead of minting per run.** Defeats
   the purpose.

## Deferred

1. Rotate the App private key on a schedule; the key is long-lived even though
   the tokens are not.
2. A Forgejo app token at migration (Consequence 5).
3. Move to a forge-native CI/runner trigger if the forge supports ephemeral
   credentials natively.
