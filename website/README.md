# Lumen website

The marketing + docs site for [Lumen](https://github.com/haviduck/lumen). 
Built with Next.js 15 (App Router), Tailwind CSS, and the same Nord-flavoured 
palette the IDE uses, so the site doesn't feel like a separate product.

## Local dev

```powershell
cd website
npm install
npm run dev
```

Visit <http://localhost:3000>.

## Production build (sanity check locally)

```powershell
npm run build
npm run start
```

## Deploy to Vercel

This is a standard Next.js app. Two paths:

### Option A — deploy from this monorepo

1. Push the repo to GitHub (already done in your case).
2. In Vercel: **Add New… → Project → Import** the `lumen` repo.
3. Under **Framework Preset** keep `Next.js`.
4. Set **Root Directory** to `website`.
5. Build / output settings: leave the defaults. Vercel will auto-detect.
6. Deploy.

### Option B — extract to its own repo

If you{'`'}d rather keep the marketing site separate from the IDE source:

```powershell
# from the lumen repo root
Copy-Item -Recurse .\website C:\path\to\new\lumen-website
cd C:\path\to\new\lumen-website
git init
git add .
git commit -m "init: lumen website"
gh repo create lumen-website --public --source=. --push
```

Then point Vercel at the new repo with Root Directory = `.`.

## Updating content

- **Latest version + download URLs:** `lib/product.ts` — bump `LATEST_VERSION` 
  when you cut a release. The Hero, Download cards, and Footer all read from 
  this one constant. URLs use the GitHub `/releases/latest/download/<asset>` 
  pattern, so they always point at the most recent release.
- **Feature copy:** `components/Features.tsx`.
- **Screenshots:** `public/screenshots/`. Source-of-truth is 
  `<repo-root>/docs/screenshots/`; copy them in with 
  `Copy-Item ..\docs\screenshots\*.png .\public\screenshots\ -Force` after 
  updates.
- **Docs page:** `app/docs/page.tsx`. Sections are anchored — update the 
  `SECTIONS` array if you add or remove an `h2`.
- **OG image:** generated at build time from `app/opengraph-image.tsx`. Edit 
  the JSX to retheme.
- **Palette:** `tailwind.config.ts` mirrors `lib/theme/duck_colors.dart`. If 
  you retheme the IDE, retheme here too.

## Project shape

```
website/
  app/
    layout.tsx              # root layout + metadata
    page.tsx                # / (home)
    docs/page.tsx           # /docs
    not-found.tsx           # custom 404
    opengraph-image.tsx     # dynamic OG image
    globals.css             # tokens, prose, .glass, .pill, buttons
  components/
    Nav.tsx Footer.tsx Logo.tsx
    Hero.tsx Pillars.tsx Features.tsx
    Screenshots.tsx Download.tsx FAQ.tsx
  lib/
    product.ts              # single source of truth: version + URLs
  public/
    favicon.png lumen-mark.png
    screenshots/*.png
  tailwind.config.ts postcss.config.mjs
  next.config.mjs tsconfig.json package.json
```

## Image sizing note

The screenshots in `public/screenshots/` are 1{'\u2013'}2.4 MB raw PNGs (full 
res, captured straight from the IDE). Vercel{'`'}s build pipeline auto-generates 
AVIF + WebP variants via `next/image` so end-users won{'`'}t pay that cost on 
the wire, but you can shrink the source files (TinyPNG, squoosh) if you{'`'}d 
prefer smaller deployment artifacts.
