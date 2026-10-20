# Mission: Cartodiagram Thematic Map plugin for geOrchestra Superset 6.1

## Goal

Build a custom geOrchestra Superset 6.1 Docker image with the **Thematic Map**
chart type enabled (part of the `plugin-chart-cartodiagram` package, developed
by terrestris). geOrchestra's fork ships only the base Cartodiagram chart —
the Thematic Map variant is missing.

## Background / analysis

- `georchestra/superset` (repo) is a deployment/config wrapper only — no
  Dockerfile, no frontend source. It holds `docker-compose.superset.yml` and
  geOrchestra-specific config (`superset_georchestra_config.py`).
- The actual buildable fork is **`georchestra/superset-core`**, branch
  `6.1-georchestra`. This is a fork of Apache Superset with a normal
  multi-stage `Dockerfile` (node build stage → python image; targets `lean`,
  `dev`, `ci`, `showtime`).
- `plugin-chart-cartodiagram` is already vendored in that fork at
  `superset-frontend/plugins/plugin-chart-cartodiagram` and registered in
  `superset-frontend/src/visualizations/presets/MainPreset.ts`. But it's an
  old snapshot — `src/thematic/` (the whole Thematic Map plugin, its own
  `ChartPlugin` subclass with `buildQuery`/`controlPanel`/`transformProps`)
  does not exist there.
- The upstream source for Thematic Map is `terrestris/superset`, which has
  many branches. **Use `6.1.0-custom`**, not `5.0.0-custom`:
  - `5.0.0-custom` targets `ol@^7.5.2` + `antd@4.10.3` (Superset 5.0 stack).
  - `6.1.0-custom` targets `ol@^10.8.0` + `antd@^5.26.0` — this **matches**
    geOrchestra's `6.1-georchestra` dependency stack exactly (confirmed by
    diffing root `superset-frontend/package.json` on both sides).
  - Using `5.0.0-custom` would require backporting across two major-version
    bumps (OpenLayers 7→10, antd 4→5) — avoid.
- A full recursive git-tree diff (blob SHA comparison) between
  `georchestra/superset-core@6.1-georchestra` and
  `terrestris/superset@6.1.0-custom` for the `plugin-chart-cartodiagram`
  directory confirmed:
  - **Zero files exist only in geOrchestra's copy** — nothing geOrchestra-
    specific is at risk from a wholesale replace.
  - Files only in terrestris: the entire `src/thematic/` tree, plus new
    shared utils (`bootstrapDataUtil.ts`, `dataUtil.ts`, `lassoUtil.ts`,
    `constants.ts`) and a `MapMaxExtentControl` component — all additive.
  - Files in both but changed: base Cartodiagram plugin also evolved
    (`plugin/*`, `util/*`, `types.ts`, `typeguards.ts`, `OlChartMap.tsx`,
    the package's own `package.json`). Since dependency versions already
    match, taking these wholesale is safe.
  - Conclusion: **replace the whole `plugin-chart-cartodiagram/` directory**
    rather than cherry-picking just the thematic files.

## Steps to reproduce

### 1. Clone geOrchestra fork (shallow, single branch — full apache/superset
history is huge)

```bash
mkdir -p ~/dev/superset-geobretagne
cd ~/dev/superset-geobretagne
git clone --depth 1 --branch 6.1-georchestra \
  https://github.com/georchestra/superset-core.git
```

### 2. Sparse-checkout only the plugin dir from terrestris (avoids full clone)

```bash
cd ~/dev/superset-geobretagne
git clone --no-checkout --depth 1 --branch 6.1.0-custom --filter=blob:none \
  https://github.com/terrestris/superset.git terrestris-src
cd terrestris-src
git sparse-checkout init --cone
git sparse-checkout set superset-frontend/plugins/plugin-chart-cartodiagram
git checkout
```

### 3. Replace the plugin directory wholesale

```bash
cd ~/dev/superset-geobretagne
GEOR_PLUGIN=superset-core/superset-frontend/plugins/plugin-chart-cartodiagram
TERR_PLUGIN=terrestris-src/superset-frontend/plugins/plugin-chart-cartodiagram
mv "$GEOR_PLUGIN" "${GEOR_PLUGIN}.bak"   # or trash/rm — it's git-tracked, reversible
cp -r "$TERR_PLUGIN" "$GEOR_PLUGIN"
```

Verify no imports in the copied plugin escape its own directory boundary
(would indicate a missing dependency from outside `plugins/plugin-chart-cartodiagram/`):

```bash
cd superset-core
grep -rnE "from ['\"]\.\./\.\./\.\./" superset-frontend/plugins/plugin-chart-cartodiagram/src/
# expect: no output
```

### 4. Register `ThematicMapPlugin` in `MainPreset.ts`

File: `superset-core/superset-frontend/src/visualizations/presets/MainPreset.ts`

Add to the import:

```ts
import {
  CartodiagramPlugin,
  ThematicMapPlugin,
} from '@superset-ui/plugin-chart-cartodiagram';
```

Add to the plugin list (after the existing `CartodiagramPlugin` registration):

```ts
new ThematicMapPlugin().configure({ key: 'thematic_map' }),
```

### 5. Fix #1 — `geostyler-legend` broken ESM export (webpack error)

`geostyler-legend@5.2.1` (a dependency pulled in by the thematic plugin)
ships `dist/index.js` containing:

```js
export * from './LegendRenderer/LegendRenderer';
```

— missing the `.js` extension, which fails webpack 5's strict "fully
specified" ESM resolution (the package declares `"type": "module"`). This is
an upstream packaging bug (still present in 5.2.1, the latest version at time
of writing — no newer patch fixes it).

geOrchestra's `webpack.config.js` already has the identical fix applied for
two other geostyler packages — just extend the regex:

File: `superset-core/superset-frontend/webpack.config.js` (~line 493)

```js
// before
test: /node_modules\/(geostyler-style|geostyler-qgis-parser)\/.*\.js$/,
// after
test: /node_modules\/(geostyler-style|geostyler-qgis-parser|geostyler-legend)\/.*\.js$/,
```

Without this fix, `npm run build` fails with:
```
ERROR in ./plugins/plugin-chart-cartodiagram/node_modules/geostyler-legend/dist/index.js
Module not found: Error: Can't resolve './LegendRenderer/LegendRenderer'
```

### 6. Fix #2 — stale/incomplete `package-lock.json` (npm ci EUSAGE in Docker)

The swapped plugin's `package.json` adds new dependencies (`proj4`, `jsts`,
`lodash-es`, `geostyler-legend`) not yet in the root lockfile. Also,
independently of this change, geOrchestra's `package-lock.json` had **pre-
existing drift**: three local workspace packages under `eslint-rules/`
(`eslint-plugin-i18n-strings`, `eslint-plugin-icons`,
`eslint-plugin-theme-colors`) were missing their required top-level
`packages["eslint-rules/<name>"]` self-descriptor entries in the lockfile
(lockfile format v3 requires one per workspace member, separate from the
`node_modules/<name>` resolution entry). This is leftover from what looks
like an old `tools/` → `eslint-rules/` rename (stale `tools/eslint-*`
"extraneous" entries still visible in the lockfile).

**Symptom:** host's npm 9.2.0 tolerates the gap silently, but the Docker
image's `node:20-trixie-slim` base ships npm ~10.8.x, which enforces it
strictly — `npm ci` fails inside the container with:
```
npm error code EUSAGE
npm error Invalid: lock file's eslint-plugin-i18n-strings@1.0.0 does not satisfy ...
npm error Missing: eslint-plugin-i18n-strings@ from lock file
```

**Fix:** regenerate the lockfile using the *same npm version the container
uses* (not whatever npm is on your host) — otherwise the lockfile you produce
may still not satisfy the container's stricter `ci` check.

```bash
cd superset-core/superset-frontend
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true   # skip Chromium download, matches Dockerfile env
npx -y npm@10.8.2 install
```

Confirm the fix:
```bash
grep -n '"eslint-rules/eslint-plugin-i18n-strings"\|"eslint-rules/eslint-plugin-icons"\|"eslint-rules/eslint-plugin-theme-colors"' package-lock.json
# expect: 3 matches (top-level self-descriptor entries now present)
```

### 7. (Optional but recommended) Verify the frontend builds standalone first

Faster feedback loop than a full Docker build — catches TS/webpack errors in
~1-2 min instead of waiting through the full multi-stage Docker build.

```bash
cd superset-core/superset-frontend
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
npm run build
```

Confirm both viz types made it into the output bundle:
```bash
cd ../superset/static/assets
grep -rl "thematic_map" . | head -1
grep -rl "cartodiagram" . | head -1
# both should return at least one match
```

Note: this local build output is **not** used by the Docker image directly —
the Dockerfile redoes `npm ci && npm run build` inside its own build stage.
This step is purely a fast pre-check.

### 8. Build the Docker image

Requires membership in the `docker` group, or `sudo`.

```bash
cd ~/dev/superset-geobretagne/superset-core
sudo docker build --target lean -t superset-geobretagne:6.1-thematic .
```

`--target lean` = production image (see Dockerfile for other targets: `dev`,
`ci`, `showtime`).

### 9. Push to registry (repo.geobretagne.fr)

Plain Docker registry v2, standard https (443, no port needed in the tag).

```bash
sudo docker login repo.geobretagne.fr
sudo docker tag superset-geobretagne:6.1-thematic repo.geobretagne.fr/superset-geobretagne:6.1-thematic
sudo docker push repo.geobretagne.fr/superset-geobretagne:6.1-thematic
```

If push fails with "denied" / "name invalid", the registry likely enforces a
namespace/project prefix — check the exact error and adjust the image name
accordingly. Optionally `sudo docker logout repo.geobretagne.fr` afterwards
if this is a shared machine.

### 10. Not yet done (next steps)

- Point geOrchestra's `docker-compose.superset.yml` (in the `georchestra/superset`
  config repo, not `superset-core`) at
  `repo.geobretagne.fr/superset-geobretagne:6.1-thematic` instead of the
  upstream image.
- Run the stack, confirm "Thematic Map" appears as a chart type in the
  Superset UI and actually renders a chart.
- Decide on a rebuild process for when either upstream fork updates.

## Key facts to remember

- Source branch pairing that actually matches dependency-wise:
  `georchestra/superset-core@6.1-georchestra` ↔ `terrestris/superset@6.1.0-custom`.
  Do **not** use terrestris's `5.0.0-custom` for a 6.1 target — dependency
  majors don't match (ol 7 vs 10, antd 4 vs 5).
- Two bugs fixed were both pre-existing/upstream issues surfaced by this
  change, not caused by incorrect porting:
  1. `geostyler-legend@5.2.1` upstream ESM export bug (webpack fix, mirrors
     an existing pattern already in geOrchestra's `webpack.config.js`).
  2. Lockfile drift for `eslint-rules/*` local packages, exposed by the
     container's stricter npm 10 vs host's npm 9 — unrelated to cartodiagram/
     thematic, would eventually have bitten any Docker build attempt.
- Always regenerate `package-lock.json` with the same npm version the
  Dockerfile's base image uses, not whatever's on the host — version
  differences in strictness caused real build failures here.
