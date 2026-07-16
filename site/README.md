# coralstack.org — public site

Hand-written static page, no framework, no build step, zero external requests
(system fonts, inline SVG favicon). `index.html` is the whole site. The copy
source-of-truth and its rationale live in [docs/SITE_COPY.md](../docs/SITE_COPY.md).

## Deploy model

`.github/workflows/pages.yml` deploys `site/` to GitHub Pages on every push to
`main` that touches `site/**`. The workflow is **inert until Pages is enabled**
in the repo settings — that switch is the deliberate publish gate.

## Publishing (one-time, admin)

Do not publish before the pre-publish checklist at the bottom of
[SITE_COPY.md](../docs/SITE_COPY.md) is green (SEC-1 remediated, initial photo
backup completed).

1. Repo **Settings → Pages → Source: GitHub Actions**.
2. Same page → **Custom domain: `coralstack.org`** (GitHub creates the domain
   check; keep "Enforce HTTPS" on once available).
3. At the registrar, point the apex at GitHub Pages:
   - `A` records → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   - optionally `AAAA` → `2606:50c0:8000::153`, `…8001::153`, `…8002::153`, `…8003::153`
   - `www` `CNAME` → `dustindoan.github.io` (Pages redirects it to the apex)
4. Re-run the workflow (Actions → "Deploy site to GitHub Pages" →
   `workflow_dispatch`) or push any `site/**` change to `main`.

## Editing

Edit `index.html`, open it locally in a browser to check, merge to `main` —
the workflow redeploys. Keep it a single file; if it ever needs more than that,
revisit whether the addition belongs on the landing page at all.
