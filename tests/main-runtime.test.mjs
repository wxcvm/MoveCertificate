import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { executableTypeScript } from './vm-typescript.mjs';

const file = fileURLToPath(new URL('../webdev/src/main.ts', import.meta.url));
const code = executableTypeScript(readFileSync(file, 'utf8'));

function element(id) {
    const classes = new Set();
    const handlers = new Map();
    return {
        id, value: '', textContent: '', disabled: false, childNodes: [],
        classList: {
            add: value => classes.add(value),
            remove: value => classes.delete(value),
            contains: value => classes.has(value),
            toggle: (value, enabled) => {
                if (enabled === undefined ? !classes.has(value) : enabled) {
                    classes.add(value); return true;
                }
                classes.delete(value); return false;
            },
        },
        style: { setProperty() {} },
        getAttribute(name) { return this.attributes?.[name] ?? null; },
        getBoundingClientRect() { return { left: 0, width: 120 }; },
        addEventListener(name, callback) { handlers.set(name, callback); },
        async click() {
            return await handlers.get('click')?.({ stopPropagation() {} });
        },
        append(...children) { this.childNodes.push(...children); },
        set innerHTML(_) { this.childNodes = []; },
        querySelector() { return null; },
        querySelectorAll() { return []; },
        closest() { return null; },
    };
}

function fixture(options = {}) {
    const ids = new Map();
    for (const id of [
        'certificateList', 'versionInfo', 'refreshCertsBtn', 'refreshLogBtn',
        'healthCheckBtn', 'healthPids', 'healthStatus', 'healthOutput',
        'modeConfig', 'logContent', 'tab-certs', 'tab-mode',
    ]) ids.set(id, element(id));
    const certTab = element('certTab');
    certTab.attributes = { 'data-tab': 'certs' };
    const modeTab = element('modeTab');
    modeTab.attributes = { 'data-tab': 'mode' };
    const logTab = element('logTab');
    logTab.attributes = { 'data-tab': 'log' };
    const tabs = [certTab, modeTab, logTab];
    const tabBar = element('tabBar');
    tabBar.querySelector = () => tabs.find(tab => tab.classList.contains('active')) ?? null;
    const translated = element('label');
    translated.attributes = { 'data-i18n': 'healthCheck' };
    const events = [];
    let shouldFailRefresh = false;
    const document = {
        getElementById: id => ids.get(id) ?? null,
        querySelectorAll: selector => {
            if (selector === '[data-i18n]') return [translated];
            if (selector === '.tab-page') return [ids.get('tab-certs'), ids.get('tab-mode')];
            if (selector === '.tab-item') return tabs;
            return [];
        },
        querySelector: selector => selector === '.tab-bar' ? tabBar : null,
        addEventListener() {},
    };
    const window = {};
    const context = vm.createContext({
        window, document, console: { error: (...args) => events.push(['error', ...args]) },
        t: (key, ...args) => key + (args.length ? ':' + args.join(',') : ''),
        getLang: () => 'en', setLang: code => events.push(['lang', code]),
        LANG_LABELS: { en: 'English' },
        fullScreen: flag => events.push(['fullScreen', flag]),
        toast: message => events.push(['toast', message]),
        initTheme() {}, bindThemeButtons() {},
        getVersionInfo: async () => ['name=MoveCertificate'],
        getInstallCertResults: async () => {
            if (shouldFailRefresh) throw new Error('transient read failure');
            return [{ id: 'a', name: 'Original CA' }];
        },
        getLoggerInfo: async () => ['boot ok'],
        getCurrentMode: async () => 'compatible',
        getRuntimeInfo: async () => ({ sdk: 37, state: 'ready', effectiveMode: 'compatible' }),
        getHealthDiagnostic: options.diagnostic ?? (async pid => ({ status: 0, output: 'checked:' + pid })),
        setCertEnabled: async () => {},
        setMode: async mode => { events.push(['setMode', mode]); },
        deleteCert: async () => {},
        renderVersionInfo: (id, lines) => { ids.get(id).textContent = lines.join('\n'); },
        renderLogInfo: (id, lines) => { ids.get(id).textContent = lines.join('\n'); },
        renderCertList: (id, rows) => {
            ids.get(id).append(...rows.map(row => ({ certificate: row.name })));
        },
        renderModeConfig: (_, mode) => events.push(['renderMode', mode]),
        showSkeleton: id => { ids.get(id).childNodes = [{ skeleton: true }]; },
        hideSkeleton: id => { ids.get(id).childNodes = []; },
        createModal: () => ({ show: name => events.push(['modal', name]), hide() {}, onConfirm() {} }),
    });
    vm.runInContext(code, context, { filename: file });
    return {
        window, ids, tabs, events, context,
        failNextRefresh() { shouldFailRefresh = true; },
    };
}

test('startup binds a read-only health check and reports successful PID verification', async () => {
    const h = fixture();
    await h.window.onload();
    h.ids.get('healthPids').value = '123 456';
    await h.ids.get('healthCheckBtn').click();
    assert.equal(h.ids.get('healthOutput').textContent, 'checked:123 456');
    assert.equal(h.ids.get('healthStatus').textContent, 'healthPassed');
    assert.equal(h.ids.get('healthCheckBtn').disabled, false);
    assert.equal(h.ids.get('certificateList').childNodes.length, 0);
    assert.ok(h.events.some(event => event[0] === 'fullScreen' && event[1] === false));
});

test('nonzero health status is not misrepresented as a success', async () => {
    const h = fixture({ diagnostic: async () => ({ status: 2, output: 'reason=missing_manifest' }) });
    await h.window.onload();
    await h.ids.get('healthCheckBtn').click();
    assert.equal(h.ids.get('healthStatus').textContent, 'healthAttention');
    assert.equal(h.ids.get('healthOutput').textContent, 'reason=missing_manifest');
    assert.equal(h.ids.get('healthCheckBtn').disabled, false);
});

test('health check exceptions surface error and re-enable button', async () => {
    const h = fixture({ diagnostic: async () => { throw new Error('root denied'); } });
    await h.window.onload();
    await h.ids.get('healthCheckBtn').click();
    assert.equal(h.ids.get('healthStatus').textContent, 'healthError');
    assert.match(h.ids.get('healthOutput').textContent, /root denied/);
    assert.equal(h.ids.get('healthCheckBtn').disabled, false);
});

test('certificate refresh failure restores the previous rendered nodes and handlers', async () => {
    const h = fixture();
    await h.window.onload();
    await vm.runInContext('loadCertList(true)', h.context);
    const previous = h.ids.get('certificateList').childNodes[0];
    assert.equal(previous.certificate, 'Original CA');
    h.failNextRefresh();
    await vm.runInContext('loadCertList(true)', h.context);
    assert.equal(h.ids.get('certificateList').childNodes.length, 1);
    assert.equal(h.ids.get('certificateList').childNodes[0], previous);
    assert.ok(h.events.some(event => event[0] === 'toast' && event[1] === 'getCertListFailed'));
});

test('mode and log tabs retain normal lazy-loading behavior', async () => {
    const h = fixture();
    await h.window.onload();
    await h.tabs[1].click();
    await vm.runInContext('loadModeTab()', h.context);
    assert.ok(h.events.some(event => event[0] === 'renderMode' && event[1] === 'compatible'));
    await h.tabs[2].click();
    await vm.runInContext('loadLogTab()', h.context);
    assert.equal(h.ids.get('logContent').textContent, 'boot ok');
    await h.ids.get('refreshLogBtn').click();
    assert.equal(h.ids.get('logContent').textContent, 'boot ok');
});
