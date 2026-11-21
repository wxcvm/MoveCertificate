// Convert V8's genuine execution ranges from node:test VM scripts to LCOV.
// The tests execute the production TypeScript with original source filenames
// and erase TypeScript syntax without moving byte/code-unit positions.
// This script does not synthesize hits for untested code.
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { executableTypeScript } from '../tests/vm-typescript.mjs';

const [profileDirectory = 'coverage/v8', destination = 'coverage/lcov.info'] = process.argv.slice(2);
const root = process.cwd();
const names = ['webdev/src/cert-service.ts', 'webdev/src/constants.ts', 'webdev/src/i18n.ts', 'webdev/src/main.ts'];
const entries = new Map(names.map(name => {
    const source = readFileSync(resolve(root, name), 'utf8');
    const code = executableTypeScript(source);
    const lines = code.split('\n');
    const lineStarts = [];
    let offset = 0;
    for (const line of lines) {
        lineStarts.push(offset);
        offset += line.length + 1;
    }
    return [resolve(root, name), {
        name, code, lines, lineStarts,
        checked: new Map(), profiles: 0,
    }];
}));

function parseUrl(url) {
    if (url.startsWith('file://')) {
        try { return fileURLToPath(url); } catch { return null; }
    }
    return url.startsWith('/') ? url : null;
}

function sourceLineIsExecutable(line) {
    const value = line.trim();
    return !!value && !/^(\/\/|\/\*|\*|\*\/)/.test(value);
}

function positionCovered(position, ranges) {
    // V8 reports nested function/block ranges; the innermost range wins.
    // Without this rule an executed top-level script would falsely mark
    // the body of an uncalled function as covered.
    let selected = null;
    for (const range of ranges) {
        if (position >= range.startOffset && position < range.endOffset) {
            if (!selected || (range.endOffset - range.startOffset) <
                (selected.endOffset - selected.startOffset)) selected = range;
        }
    }
    return selected !== null && selected.count > 0;
}

let seenScripts = 0;
for (const file of readdirSync(profileDirectory).filter(name => name.endsWith('.json'))) {
    const json = JSON.parse(readFileSync(join(profileDirectory, file), 'utf8'));
    for (const script of json.result ?? []) {
        const fullPath = parseUrl(script.url ?? '');
        const entry = fullPath && entries.get(resolve(fullPath));
        if (!entry || !Array.isArray(script.functions)) continue;
        seenScripts++;
        entry.profiles++;
        const ranges = script.functions.flatMap(fn => fn.ranges ?? []);
        // Inspect each source line, not its source-map-free test wrapper.
        for (let i = 0; i < entry.lines.length; i++) {
            const line = entry.lines[i];
            if (!sourceLineIsExecutable(line)) continue;
            const first = line.search(/\S/);
            const last = line.length - 1 - line.split('').reverse().join('').search(/\S/);
            // A line counts as executed if V8 recorded an executed statement
            // within its own code. Do not count unexecuted blocks as covered.
            const probes = [first, Math.floor((first + last) / 2), last];
            const hit = probes.some(p => positionCovered(entry.lineStarts[i] + p, ranges)) ? 1 : 0;
            entry.checked.set(i + 1, Math.max(entry.checked.get(i + 1) ?? 0, hit));
        }
    }
}
if (!seenScripts) {
    throw new Error('No production TypeScript VM coverage profiles found; refusing to emit empty/fabricated LCOV');
}
const report = [];
let totalHits = 0;
let totalLines = 0;
for (const entry of entries.values()) {
    if (!entry.profiles) throw new Error('Missing V8 execution profile for ' + entry.name);
    report.push('TN:MoveCertificate', 'SF:' + entry.name);
    let hit = 0;
    for (const [line, count] of [...entry.checked.entries()].sort((a, b) => a[0] - b[0])) {
        report.push('DA:' + line + ',' + count);
        if (count > 0) hit++;
    }
    totalHits += hit;
    totalLines += entry.checked.size;
    report.push('LF:' + entry.checked.size, 'LH:' + hit, 'end_of_record');
    console.log('V8 line coverage:', entry.name, hit + '/' + entry.checked.size,
        '(samples=' + entry.profiles + ')');
}
if (totalHits < 10 || totalLines < 20) {
    throw new Error('Unexpectedly small real coverage; refusing to publish an invalid report');
}
mkdirSync(dirname(destination), { recursive: true });
writeFileSync(destination, report.join('\n') + '\n');
console.log('LCOV from executed source lines:', destination, 'hits=' + totalHits, 'lines=' + totalLines);
