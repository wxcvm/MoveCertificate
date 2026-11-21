import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { executableTypeScript } from './vm-typescript.mjs';

const file = fileURLToPath(new URL('../webdev/src/i18n.ts', import.meta.url));
const code = executableTypeScript(readFileSync(file, 'utf8'));

function fixture({ saved = null, language = 'en-US' } = {}) {
    const values = new Map();
    if (saved !== null) values.set('movecert_lang', saved);
    const warnings = [];
    const context = vm.createContext({
        navigator: { language },
        localStorage: {
            getItem: key => values.get(key) ?? null,
            setItem: (key, value) => values.set(key, value),
        },
        console: { warn: message => warnings.push(message) },
    });
    vm.runInContext(code, context, { filename: file });
    const api = vm.runInContext('({getLang,setLang,t,supportedLangs,LANG_LABELS})', context);
    return { api, values, warnings };
}

test('locale detection honors explicitly chosen supported language', () => {
    const { api } = fixture({ saved: 'tr', language: 'zh-CN' });
    assert.equal(api.getLang(), 'tr');
    assert.equal(api.t('healthCheck'), 'Şimdi denetle');
    assert.equal(api.supportedLangs.length, 3);
});

test('locale detection falls back to Android/browser language', () => {
    for (const [language, expected] of [
        ['zh-Hans-CN', 'zh-CN'], ['tr-TR', 'tr'], ['en-US', 'en'],
        ['de-DE', 'en'], ['', 'en'],
    ]) {
        assert.equal(fixture({ language }).api.getLang(), expected, language);
    }
    assert.equal(fixture({ saved: 'unsupported', language: 'en-US' }).api.getLang(), 'en');
});

test('health diagnostics and placeholders react immediately to locale switches', () => {
    const { api, values } = fixture({ language: 'en-US' });
    assert.equal(api.t('healthRunning'), 'Checking…');
    assert.equal(api.t('healthPassed'), 'Checks passed (not proof of app TLS trust)');
    assert.match(api.t('healthHint'), /PIDs/);
    api.setLang('zh-CN');
    assert.equal(values.get('movecert_lang'), 'zh-CN');
    assert.equal(api.t('healthRunning'), '正在检查…');
    assert.match(api.t('healthHint'), /HTTPS/);
    assert.match(api.t('confirmDeleteCert', 'safe.0'), /safe\.0/);
    api.setLang('tr');
    assert.match(api.t('healthError'), /PID/);
    assert.equal(api.LANG_LABELS.tr, 'Türkçe');
});

test('missing translation keys are reported without rendering arbitrary HTML', () => {
    const { api, warnings } = fixture();
    assert.equal(api.t('nonexistent-key'), 'nonexistent-key');
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /nonexistent-key/);
});
