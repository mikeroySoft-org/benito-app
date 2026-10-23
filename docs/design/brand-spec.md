# Brand spec: mikeroySoft house system, Benito product

Inherited, not dealt (brand-truth.md). Sources read on 2026-10-23:
- https://www.mikeroysoft.com/css/mikeroysoft.css (shared design system)
- https://www.mikeroysoft.com/css/site.css (light tokens)
- mikeroySoft/gpuflo `site/index.html`, mikeroysoft.github.io/factory, mikeroysoft.github.io/district

## What carries over
- Faces: Newsreader (display, OFL) and JetBrains Mono (body and working voice, OFL), self-hosted from `fonts/`.
- Light ground: page #f7f1e3, panel #fcf8ef, sunken #efe7d4, ink #221c14 / #4a3d28 / #66594a, hairline #ddd2b8.
- Dark ground: page #0d0c0a, panel #1a1712, sunken #151310, ink #f0e2c8 / #a69278 / #8a7a5e, hairline #3a2f1e.
- Radii 4 to 12px; motion 150/220/400ms ease-out.
- Structure: nav brand `mikeroySoft :: <product>` with a mark, links right; hero head, tagline, install/action block and a product panel; sections of head, lead and a grid; footer with license and no-telemetry line left, links right.
- Per-product accent via `data-product` (gpuflo amber, factory sage, district terracotta).

## Benito's product accent
Night navy taken from the app icon's background (the sky behind the sleeping capybara), oklch(40% 0.13 272) on light, oklch(80% 0.08 272) on dark. Chosen over a caramel brown because the brief bans orange and every brown at accent chroma reads as rust beside the app's own red-brown feed colour.

## What does not carry over
- The house `// SECTION` labels in tracked uppercase mono: Hallmark Floor gates 54 and 67 forbid eyebrows and tracked caps. Section heads stand alone.
