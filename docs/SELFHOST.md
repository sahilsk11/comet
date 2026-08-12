# Self-hosted edge (personal)

This fork deploys the Comet edge Worker to Sahil's Cloudflare account.

- Worker: `https://comet-edge.sahilkapur-a.workers.dev`
- Auth: `AUTH_MODE=dev` (bearer token = identity, no WorkOS)

## Client / VPS env

```bash
export COMET_EDGE_URL=https://comet-edge.sahilkapur-a.workers.dev
export COMET_EDGE_TOKEN=sahil@home
export COMET_ORG_ID=home
export COMET_WORKOS_CLIENT_ID=
```

Same values on every device. VPS runs `comet headless`; laptops run headed `comet`.

## Redeploy edge

```bash
cd edge
npm ci
npx wrangler deploy
```
