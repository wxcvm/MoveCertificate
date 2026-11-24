// Keep VM-tested TypeScript in its original file and line positions so the
// V8 coverage profile can be attributed to the real source (not evalmachine).
// Node stripTypeScriptTypes preserves offsets for erased types.
import { stripTypeScriptTypes } from 'node:module';

export function executableTypeScript(text) {
    const withoutModules = text
        .replace(/^import .*?;\s*/gms, match => match.replace(/[^\n]/g, ' '))
        .replace(/^export /gm, '       ');
    const executable = stripTypeScriptTypes(withoutModules);
    if (executable.length !== text.length ||
        executable.split('\n').length !== text.split('\n').length) {
        throw new Error('TypeScript coverage source map is not position-preserving');
    }
    return executable;
}
