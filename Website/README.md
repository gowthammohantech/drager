# Website

The one-page marketing site. Plain HTML, CSS and JS with no build step and no dependencies.

```sh
open Website/index.html                      # or serve it:
python3 -m http.server -d Website 8080
```

## Files
- `index.html`: all page content.
- `styles.css`: light and dark themes (follows the system setting), responsive down to phone width.
- `main.js`: the interactive throw demo and the download links.
- `favicon.svg`: the brand mark. The apps have no icon artwork yet, so this is also a placeholder for the app icon.

## Before launch
- **Download links**: set `DOWNLOADS.ios` and `DOWNLOADS.mac` at the top of `main.js`. While a link is empty its button stays disabled and the page says "Coming soon".
- **Privacy policy**: still needed before release (BRD §9). Add `privacy.html` and link it from the footer.
- **Claims**: only say what's built and tested. The speed targets in the BRD are unmeasured, so they stay off the site until `docs/TEST_REPORT.md` has device results.
- Don't use Apple's App Store or Mac App Store badge artwork until distribution is decided. The badges have their own usage rules.

## Deploying
Any static host works (Vercel, Netlify, GitHub Pages). Set the publish directory to `Website/`.
