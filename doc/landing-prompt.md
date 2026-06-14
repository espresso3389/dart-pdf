# DartPDF landing page — Claude Design prompt

A ready-to-paste prompt for generating the project home page with Claude Design,
plus the brand facts it draws on. Scope: a consumer landing page for the
**DartPDF** app with a secondary developers/open-source section, output as a
self-contained static page suitable for static hosting (e.g. Firebase).

## Brand facts (from `doc/banner.svg` / `doc/logo.svg`)

- **Name / wordmark:** DartPDF (one word).
- **Logo motif:** a dog-eared white document page with a single amber highlighter
  bar and a blue ink swoosh.
- **Palette:** blue gradient `#16BAFD → #0169B4` (also `#13B9FD` / `#0175C2`) for
  accents and CTAs; near-black `#202124` for dark sections and text; amber
  `#FFC93C` as a single sparing highlight; light tint `#C6E3F8`; muted grey
  `#9AA0A6` / `#8FA6B5`; white "paper" surfaces.
- **Type:** clean geometric grotesk (Inter / Manrope / Helvetica Neue).
- **Voice:** plain and factual, no hype. See the copy in `app/store-listing.md`.
- **Assets:** `doc/logo.svg`, `doc/banner.svg`, screenshot `doc/dart_pdf_editor_example.jpg`.
- **Links:** browser demo https://dart-pdf-demo.web.app · repo
  https://github.com/ben-milanko/dart-pdf · packages on pub.dev.

## The prompt

> Design and build a responsive marketing landing page for **DartPDF**, a
> cross-platform PDF editor. Output a single self-contained, static page
> (HTML + CSS, minimal vanilla JS, no backend, no build step) that can be dropped
> onto static hosting. Prioritize fast load, accessibility (WCAG AA, semantic
> HTML, keyboard-navigable, proper contrast), and a polished but restrained
> aesthetic.
>
> **What DartPDF is:** a PDF editor that runs entirely on the user's device — no
> account, no sync, no ads, nothing uploaded. It runs from one codebase on
> iPhone, iPad, Mac, Android, Windows, Linux, and the web. It's built on an
> open-source, pure-Dart PDF engine (no PDFium).
>
> **Brand**
> - Name/wordmark: **DartPDF** (one word, clean geometric/grotesk sans — Inter,
>   Manrope, or Helvetica Neue).
> - Logo motif: a dog-eared white document page with a single amber highlighter
>   bar across it and a blue ink swoosh — render a tasteful CSS/SVG version if no
>   asset is supplied.
> - Palette: blue gradient `#16BAFD → #0169B4` (accents/CTAs), near-black
>   `#202124` (dark sections/text), amber `#FFC93C` (one sparing highlight,
>   echoing a highlighter), light tint `#C6E3F8`, muted grey `#9AA0A6`. White
>   surfaces for the "paper" feel. Light page with one or two dark feature bands.
> - Mood: confident, clean, a little technical — Linear / Things / Raycast
>   restraint, not a busy SaaS template. Generous whitespace, crisp type, subtle
>   motion only.
>
> **Voice (important):** plain and factual, zero hype. No exclamation marks, no
> "revolutionary/seamless/effortless," no stacked slogans. State what it does and
> let it stand. Match the copy below; don't embellish it.
>
> **Sections (in order)**
> 1. **Header/nav:** wordmark left; links Features, Privacy, Developers, GitHub; a
>    primary "Download" button.
> 2. **Hero:** headline **"Edit PDFs anywhere. Everything stays on your device."**
>    Subhead: *"A full PDF editor — annotate, fill forms, sign, redact, and edit —
>    that runs on iPhone, iPad, Mac, Android, Windows, Linux, and the web. No
>    account, no uploads."* Primary CTA "Download" (scrolls to platforms),
>    secondary "Try it in your browser" (→ https://dart-pdf-demo.web.app). Hero
>    visual: an app screenshot in a device frame (placeholder ok), with a subtle
>    amber highlight-stroke motif.
> 3. **Feature grid** (icon + short label + one plain line each): Annotate
>    (highlight, ink, shapes, notes, stamps); Forms (fill fields or create your
>    own); Sign (drawn signatures, placed anywhere); Redact; Edit text & images;
>    Pages (reorder, delete, export to a new file); Search & select text; Compare
>    two versions side by side; Open password-protected files. Keep descriptions
>    terse.
> 4. **Privacy band** (dark `#202124`): heading "Your documents never leave your
>    device." Body: *"DartPDF has no servers, no analytics, and no ads. Files are
>    processed locally and only shared when you choose to."* Link to the privacy
>    policy.
> 5. **Platforms / Download:** App Store and Google Play badges, plus a row for
>    macOS (.dmg), Windows, Linux, and Web. Placeholder hrefs; any not-yet-live
>    target reads "Coming soon." Note "Free and open source."
> 6. **Developers / open source:** "Built on an open-source, pure-Dart PDF
>    engine." One line that the rendering engine is fast (independently
>    benchmarked to match or beat PDFium) and available as packages on pub.dev.
>    CTAs: "View on GitHub" (https://github.com/ben-milanko/dart-pdf) and
>    "Packages on pub.dev."
> 7. **Footer:** wordmark, "© Railway Engineering Solutions", links (GitHub,
>    pub.dev, Privacy), and a line that DartPDF is free and open source.
>
> **Constraints:** responsive (mobile-first), dark-mode-aware if cheap, no
> external trackers, system font stack fallback, lazy-load images, modest total
> page weight. Use clearly-labeled placeholder images/icons where real assets
> aren't provided. Don't invent features beyond the list above; don't claim
> certified digital signatures (signatures are hand-drawn) or OCR.
