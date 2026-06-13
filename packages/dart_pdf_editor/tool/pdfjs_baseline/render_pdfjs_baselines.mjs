#!/usr/bin/env node
import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  createCanvas,
  DOMMatrix,
  GlobalFonts,
  ImageData,
  Path2D,
} from '@napi-rs/canvas';

globalThis.DOMMatrix ??= DOMMatrix;
globalThis.ImageData ??= ImageData;
globalThis.Path2D ??= Path2D;

const pdfjsLib = await import('pdfjs-dist/legacy/build/pdf.mjs');

const passwords = new Map([
  ['issue6010_1.pdf', 'abc'],
  ['issue6010_2.pdf', 'æøå'],
  ['issue15893_reduced.pdf', 'test'],
  ['bug1782186.pdf', 'Hello'],
  ['issue3371.pdf', 'ELXRTQWS'],
  ['encrypted-attachment.pdf', '000000'],
]);

const skipped = new Set([
  'GHOSTSCRIPT-698804-1-fuzzed.pdf',
  'Pages-tree-refs.pdf',
  'REDHAT-1531897-0.pdf',
  'poppler-395-0-fuzzed.pdf',
  'poppler-742-0-fuzzed.pdf',
  'poppler-85140-0.pdf',
  'poppler-937-0-fuzzed.pdf',
  'print_protection.pdf',
]);

const cjkSerifFonts = [
  '/System/Library/Fonts/Supplemental/Songti.ttc',
  '/System/Library/Fonts/Songti.ttc',
  '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSerifCJKsc-Regular.otf',
  '/usr/share/fonts/truetype/arphic/uming.ttc',
];

const cjkSansFonts = [
  '/System/Library/Fonts/STHeiti Medium.ttc',
  '/System/Library/Fonts/STHeiti Light.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf',
  '/usr/share/fonts/truetype/arphic/ukai.ttc',
];

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const packageDir = path.resolve(scriptDir, '../..');
const pdfjsDistDir = path.join(scriptDir, 'node_modules/pdfjs-dist');
const resourcePath = (name) => `${path.join(pdfjsDistDir, name)}${path.sep}`;

const args = parseArgs(process.argv.slice(2));
const corpusDir = path.resolve(
  process.cwd(),
  args.corpus ?? path.join(packageDir, '../../test_corpora/pdfjs'),
);
const outDir = path.resolve(
  process.cwd(),
  args.out ?? path.join(packageDir, '../../test_corpora/pdfjs/_baselines'),
);
const scale = positiveNumber(args.scale, 1);
const maxPages = positiveInteger(args['max-pages'], 5);
const only = args.only == null ? null : new RegExp(args.only);

if (!existsSync(corpusDir)) {
  throw new Error(`PDF.js corpus not found: ${corpusDir}`);
}
await mkdir(outDir, { recursive: true });

const files = (await readdir(corpusDir, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.pdf'))
  .map((entry) => entry.name)
  .filter((name) => !skipped.has(name))
  .filter((name) => only == null || only.test(name))
  .sort();

let rendered = 0;
const failures = [];
for (const name of files) {
  const fontKeys = [];
  try {
    const bytes = await readFile(path.join(corpusDir, name));
    if (needsCjkFallback(bytes)) {
      const keys = registerCjkFallbacks();
      if (keys.length === 0) {
        console.warn(
          `Warning: no local CJK fonts found; ${name} may render missing glyph boxes.`,
        );
      } else {
        fontKeys.push(...keys);
      }
    }
    const loadingTask = pdfjsLib.getDocument({
      data: new Uint8Array(bytes),
      password: passwords.get(name) ?? '',
      useSystemFonts: true,
      // In Node, @napi-rs/canvas does not load PDF.js-created FontFace
      // instances like a browser does. Force PDF.js to draw embedded glyph
      // outlines itself so CID subset fonts and CIDToGIDMap entries are used.
      disableFontFace: true,
      cMapUrl: resourcePath('cmaps'),
      cMapPacked: true,
      iccUrl: resourcePath('iccs'),
      standardFontDataUrl: resourcePath('standard_fonts'),
      wasmUrl: resourcePath('wasm'),
    });
    const pdf = await loadingTask.promise;
    const pages = Math.min(pdf.numPages, maxPages);
    for (let pageIndex = 0; pageIndex < pages; pageIndex++) {
      const page = await pdf.getPage(pageIndex + 1);
      const viewport = page.getViewport({ scale });
      const canvas = createCanvas(
        Math.ceil(viewport.width),
        Math.ceil(viewport.height),
      );
      const canvasContext = canvas.getContext('2d');
      canvasContext.fillStyle = 'white';
      canvasContext.fillRect(0, 0, canvas.width, canvas.height);
      await page.render({ canvasContext, viewport }).promise;
      const outName = `${safeName(name)}.p${pageIndex}.png`;
      await writeFile(path.join(outDir, outName), canvas.toBuffer('image/png'));
      rendered++;
    }
    await pdf.cleanup();
    await loadingTask.destroy();
    console.log(`rendered ${name} (${pages} page${pages === 1 ? '' : 's'})`);
  } catch (error) {
    failures.push(`${name}: ${error?.message ?? error}`);
    console.warn(`FAILED ${name}: ${error?.message ?? error}`);
  } finally {
    for (const key of fontKeys) {
      GlobalFonts.remove(key);
    }
  }
}

console.log(`rendered ${rendered} baseline PNGs into ${outDir}`);
if (failures.length > 0) {
  console.warn(`failed to render ${failures.length} file(s):`);
  for (const failure of failures) console.warn(`  ${failure}`);
  process.exitCode = 1;
}

function parseArgs(values) {
  const result = {};
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (!value.startsWith('--')) {
      throw new Error(`unexpected argument: ${value}`);
    }
    const eq = value.indexOf('=');
    if (eq === -1) {
      result[value.slice(2)] = values[++i];
    } else {
      result[value.slice(2, eq)] = value.slice(eq + 1);
    }
  }
  return result;
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function positiveNumber(value, fallback) {
  const parsed = Number.parseFloat(value ?? '');
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function needsCjkFallback(bytes) {
  const text = Buffer.from(bytes).toString('latin1');
  return (
    /\/BaseFont \/(?:#[0-9A-Fa-f]{2}){2,}(?:[_-]GB2312)?/.test(text) ||
    /\/FontName <(?:[0-9A-Fa-f]{4}){2,}>/.test(text)
  );
}

function registerCjkFallbacks() {
  return [
    registerFirstAvailableFont(cjkSerifFonts, 'serif'),
    registerFirstAvailableFont(cjkSansFonts, 'sans-serif'),
  ].filter((key) => key != null);
}

function registerFirstAvailableFont(fontPaths, alias) {
  for (const fontPath of fontPaths) {
    if (!existsSync(fontPath)) continue;
    const key = GlobalFonts.registerFromPath(fontPath, alias);
    if (key != null) return key;
  }
  return null;
}

function safeName(name) {
  return name.replaceAll(/[^A-Za-z0-9._-]+/g, '_');
}
