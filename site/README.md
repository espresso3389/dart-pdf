# DartPDF landing page

The marketing landing page for the **DartPDF** app — a single self-contained
static site (HTML + CSS, no build step). Generated from
[`doc/landing-prompt.md`](../doc/landing-prompt.md) via Claude Design and wired
up against the real product facts.

## Files

- `index.html` — the landing page (hero, features, privacy band, download,
  developers, footer). Self-contained: only external dependency is the Manrope
  web font from Google Fonts.
- `privacy.html` — the privacy policy, mirroring `app/PRIVACY.md`. This is the
  URL to use for the App Store / Play Store "privacy policy" listing field.
- `assets/editor-screenshot.png` — the hero screenshot of the editor.
- `firebase.json` / `.firebaserc` — Firebase Hosting config.

## Local preview

Any static server works, e.g.:

```sh
cd site && python3 -m http.server 8000   # → http://localhost:8000
```

## Deploy

Hosted on the existing **`dart-pdf-demo`** Firebase project as a second site,
so the browser demo stays at `dart-pdf-demo.web.app` and the landing page gets
its own site. One-time setup (needs Firebase auth — maintainer's manual step):

```sh
cd site
firebase hosting:sites:create dartpdf        # creates dartpdf.web.app (once)
firebase deploy --only hosting               # uses site: "dartpdf" in firebase.json
```

Then point a custom domain at it in the Firebase console if desired.

> Update the App Store / Play Store **privacy policy URL** to
> `https://dartpdf.web.app/privacy` once the site is live.
