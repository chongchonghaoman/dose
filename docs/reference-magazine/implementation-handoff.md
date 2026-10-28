# Implementation handoff

- `src/editorial-layout.js`: seeded composition grammar, recursive clusters, aspect-aware assignment and quality ranking, six reading paths with new proportions on later cycles; balanced pages up to eight.
- `src/viewport-layout.js`: shared editorial composer on one viewport-aspect paper. Include every photo; adapt cluster geometry to both dimensions, match actual aspect ratios and reduce gutters for dense collections. No ordinary grid/row fallback. Keep the chosen family during resize; explicit clicks can change it.
- `src/renderer.js`: render paper behind editable photos; include paper in fit; persist page membership; detach selected items on relayout. Existing controls toggle back to film geometry.
- `src/core.cjs`: validate page composition/variant, revision, viewport sizing and presentation. Legacy saved layouts stay unchanged until the user explicitly lays out again.
- Keep photo adjustments, decoding, ICC, high-precision export and native engine unchanged.
- Verify with both layout unit suites, packaged `tests/adaptive-layout-desktop.cjs` / `viewport-layout-desktop.cjs`, and six same-photo plus wide/tall/compact screenshots. Footer and paper never enter photo export.
