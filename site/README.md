# coralstack.org — public site

Hand-written static page, no framework, no build step, zero external requests
(system fonts, inline SVG favicon). `index.html` is the whole site. The copy
source-of-truth and its rationale live in [docs/SITE_COPY.md](../docs/SITE_COPY.md).

## Deploy model

**The site is live at <https://coralstack.org/>.** Pages is enabled
(Source: GitHub Actions), the custom domain is verified, and HTTPS is enforced.
`.github/workflows/pages.yml` redeploys `site/` on every push to `main` that
touches `site/**` — so merging a `site/**` change *is* publishing it. There is no
separate publish step and no gate to clear anymore; the initial-publish checklist
that used to live here has been satisfied.

## Initial setup (done — kept for rebuild reference)

Recorded in case Pages ever has to be re-enabled from scratch (repo transfer,
accidental disable). Not a checklist to run for normal edits.

1. Repo **Settings → Pages → Source: GitHub Actions**.
2. Same page → **Custom domain: `coralstack.org`** (Enforce HTTPS on).
3. At the registrar, apex points at GitHub Pages:
   - `A` records → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   - optionally `AAAA` → `2606:50c0:8000::153`, `…8001::153`, `…8002::153`, `…8003::153`
   - `www` `CNAME` → `dustindoan.github.io` (Pages redirects it to the apex)
4. A `site/**` push to `main` (or Actions → "Deploy site to GitHub Pages" →
   `workflow_dispatch`) deploys.

## Editing

Edit `index.html`, open it locally in a browser to check, merge to `main` —
the workflow redeploys to the live site. Keep it a single file; if it ever needs
more than that, revisit whether the addition belongs on the landing page at all.
