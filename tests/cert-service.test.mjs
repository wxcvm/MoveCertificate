import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
const source = readFileSync(new URL('../webdev/src/cert-service.ts', import.meta.url), 'utf8');
const constants = readFileSync(new URL('../webdev/src/constants.ts', import.meta.url), 'utf8');
const fingerprint = 'a'.repeat(64);
const other = 'b'.repeat(64);
const row = (id = fingerprint, user = 0, state = 'pending') => `${id}\t12345678.1\t/data/misc/user/${user}/cacerts-added/12345678.0\t${state}`;
function service(options = {}) {
    const calls = [];
    const networkCalls = [];
    const files = {
        'runtime.conf': `boot_id=boot\neffective_mode=compatible\nsystem_source=${options.source ?? (options.sdk && options.sdk < 34 ? '/system/etc/security/cacerts' : '/apex/com.android.conscrypt/cacerts')}\nstate=${options.state ?? 'ready'}\nreason=none`,
        'state/boot_id': 'boot', 'certificate-sources.tsv': options.manifest ?? row(),
        'cert_names.json': JSON.stringify({ [fingerprint]: 'Test CA', [other]: 'Other CA' }),
        'mode.conf': options.mode ?? 'mode=compatible', 'cert-selection.tsv': options.selections ?? '', ...options.files,
    };
    const context = vm.createContext({ console, setTimeout, clearTimeout, AbortController, TextEncoder, btoa, crypto: webcrypto,
        exec: async command => {
            calls.push(command);
            if (options.exec) { const result = options.exec(command); if (result) return result; }
            const result = { errno: 0, stderr: '', stdout: '' };
            if (command === 'getprop ro.build.version.sdk') result.stdout = String(options.sdk ?? 37);
            else if (command === 'cat /proc/sys/kernel/random/boot_id') result.stdout = 'boot';
            else if (command.startsWith('if [ ! -e')) {
                const key = Object.keys(files).find(k => command.includes('/' + k));
                result.stdout = key && files[key] !== null ? files[key] : '__MISSING__';
            } else if (command.includes('cmp -s')) result.errno = options.cmpError ?? 0;
            else if (command.includes('for d in')) result.stdout = '/data/misc/user/10/cacerts-added/87654321.0';
            else if (command.includes('set-mode.sh')) files['mode.conf'] = "mode=" + (command.endsWith("'builtin'") ? 'builtin' : 'compatible');
            else if (command.includes('set-cert-enabled.sh')) files['cert-selection.tsv'] = fingerprint + '\t' + (command.endsWith('1') ? '1' : '0');
            return result;
        }, fetch: async (...args) => { networkCalls.push(args); throw new Error('certificate lookup must be offline'); },
    });
    const code = stripTypeScriptTypes(constants.replaceAll('export ', '') + '\n' + source
        .replace(/^import .*?;\s*/gms, '').replaceAll('export ', ''));
    vm.runInContext(code + '\nthis.api={getInstallCertResults,getRuntimeInfo,getCurrentMode,setMode,deleteCert,readFileBase64,getVersionInfo,setCertEnabled,getHealthDiagnostic,getCertName};', context);
    return { api: context.api, calls, networkCalls };
}
test('all user sources deduplicate by fingerprint, not subject filename', async () => {
    const { api } = service({ manifest: [row(), row(fingerprint, 10), row(other, 11)].join('\n') });
    const certs = await api.getInstallCertResults();
    assert.equal(certs.length, 2); assert.equal(certs[0].sources.length, 2); assert.equal(certs[0].id, fingerprint);
    assert.equal(certs[0].status, 'success');
});
test('content mismatch fails even when the target filename exists', async () => {
    const { api, calls } = service({ cmpError: 1 });
    assert.equal((await api.getInstallCertResults())[0].status, 'failed');
    assert.ok(calls.some(c => c.includes('cmp -s')));
});
test('runtime failure and preparation cannot show a green success', async () => {
    for (const [state, expected] of [['failed', 'failed'], ['prepared', 'unknown']]) {
        assert.equal((await service({ state }).api.getInstallCertResults())[0].status, expected);
    }
});
test('previous boot status is not treated as active after safe mode', async () => {
    const { api } = service({ files: { 'runtime.conf': 'boot_id=old\neffective_mode=builtin\nstate=ready' } });
    assert.equal((await api.getRuntimeInfo()).effectiveMode, null);
    assert.equal((await api.getInstallCertResults())[0].status, 'unknown');
});
test('missing current manifest shows multi-user inputs as unknown and disables deletion', async () => {
    const { api } = service({ files: { 'certificate-sources.tsv': null } });
    const certs = await api.getInstallCertResults();
    assert.equal(certs[0].sources[0], '/data/misc/user/10/cacerts-added/87654321.0');
    assert.equal(certs[0].status, 'unknown'); assert.equal(certs[0].canDelete, false);
});
test('policy exclusion and removed sources have distinct states', async () => {
    for (const state of ['excluded', 'unverified', 'removed']) {
        const cert = (await service({ manifest: row(fingerprint, 0, state) }).api.getInstallCertResults())[0];
        assert.equal(cert.status, state); assert.equal(cert.canDelete, state !== 'removed');
    }
});
test('malformed source provenance is rejected', async () => {
    await assert.rejects(service({ manifest: row().replace('/data/misc/user/0/cacerts-added', '/system/etc/security/cacerts') }).api.getInstallCertResults());
});
test('Android 14 through 17 builtin selection is saved for mount-provider boot verification', async () => {
    for (const sdk of [34, 35, 36, 37]) {
        const { api, calls } = service({ sdk });
        await api.setMode('builtin');
        assert.equal(await api.getCurrentMode(), 'builtin');
        assert.ok(calls.some(c => c.includes('set-mode.sh')));
    }
});
test('comment text is not interpreted as the selected mode', async () => {
    assert.equal(await service({ mode: '# formerly builtin\nmode=compatible' }).api.getCurrentMode(), 'compatible');
});
test('configuration write errors propagate to the UI', async () => {
    const { api } = service({ sdk: 35, exec: c => c.includes('set-mode.sh') ? { errno: 1, stdout: '', stderr: 'write failed' } : null });
    await assert.rejects(api.setMode('builtin'), /write failed/);
});
test('deletion uses a fingerprint helper and propagates errors', async () => {
    const { api, calls } = service({ exec: c => c.includes('delete-cert.sh') ? { errno: 1, stdout: '', stderr: 'source changed' } : null });
    await assert.rejects(api.deleteCert(fingerprint), /source changed/);
    assert.ok(calls.some(c => c.includes('delete-cert.sh') && c.includes(fingerprint)));
    assert.ok(!calls.some(c => c.startsWith('rm ')));
    await assert.rejects(api.deleteCert('12345678.0'));
});
test('shell read failures cannot masquerade as successful empty results', async () => {
    const { api } = service({ exec: () => ({ errno: 1, stdout: '', stderr: 'denied' }) });
    await assert.rejects(api.getVersionInfo()); await assert.rejects(api.readFileBase64('/missing'));
});
test('unmount preference leaves the current mounted result visible until reboot', async () => {
    const { api } = service({ selections: fingerprint + '\t0' });
    const cert = (await api.getInstallCertResults())[0];
    assert.equal(cert.status, 'success'); assert.equal(cert.enabled, false);
    assert.equal(cert.canToggle, true); assert.equal(cert.pendingChange, true);
});
test('AdGuard/default disabled inputs are selectable without deletion', async () => {
    const { api } = service({ manifest: row(fingerprint, 0, 'disabled'), selections: fingerprint + '\t1' });
    const cert = (await api.getInstallCertResults())[0];
    assert.equal(cert.status, 'disabled'); assert.equal(cert.enabled, true); assert.equal(cert.pendingChange, true);
    assert.equal(cert.canToggle, true);
});
test('native and unverified CAs cannot be changed by user migration toggles', async () => {
    for (const state of ['native', 'unverified', 'removed']) {
        assert.equal((await service({ manifest: row(fingerprint, 0, state) }).api.getInstallCertResults())[0].canToggle, false);
    }
});
test('selection writes use a dedicated helper and verify saved preferences', async () => {
    const { api, calls } = service();
    await api.setCertEnabled(fingerprint, false);
    assert.ok(calls.some(c => c.includes('set-cert-enabled.sh') && c.endsWith('0')));
    assert.ok(!calls.some(c => c.includes('delete-cert.sh') || c.startsWith('rm ')));
});
test('failed selection writes do not report success', async () => {
    const { api } = service({ exec: c => c.includes('set-cert-enabled.sh') ? { errno: 1, stderr: 'write failed', stdout: '' } : null });
    await assert.rejects(api.setCertEnabled(fingerprint, false), /write failed/);
});

test('Android 14+ runtime system fallback chooses the legacy path instead of SDK-based APEX', async () => {
    const { api, calls } = service({ sdk: 37, source: '/system/etc/security/cacerts' });
    const runtime = await api.getRuntimeInfo();
    assert.equal(runtime.systemSource, '/system/etc/security/cacerts/');
    assert.equal((await api.getInstallCertResults())[0].status, 'success');
    assert.ok(calls.some(c => c.includes('cmp -s') && c.includes('/system/etc/security/cacerts/12345678.1')));
    assert.ok(!calls.some(c => c.includes('cmp -s') && c.includes('/apex/com.android.conscrypt/cacerts/12345678.1')));
});
test('untrusted or absent runtime source never produces green or guessed red statuses', async () => {
    for (const source of ['', '/system/etc/security/not-the-system-store']) {
        const { api, calls } = service({ source });
        const runtime = await api.getRuntimeInfo();
        assert.equal(runtime.systemSource, null);
        assert.equal((await api.getInstallCertResults())[0].status, 'unknown');
        assert.ok(!calls.some(c => c.includes('cmp -s')));
    }
});
test('stale boot snapshot never selects a system CA verification path', async () => {
    const { api, calls } = service({
        files: { 'runtime.conf': 'boot_id=old\neffective_mode=compatible\nsystem_source=/apex/com.android.conscrypt/cacerts\nstate=ready' },
    });
    assert.equal((await api.getRuntimeInfo()).systemSource, null);
    assert.equal((await api.getInstallCertResults())[0].status, 'unknown');
    assert.ok(!calls.some(c => c.includes('cmp -s')));
});

test('health diagnostic rejects shell syntax and malformed PIDs before execution', async () => {
    const { api, calls } = service();
    await assert.rejects(api.getHealthDiagnostic('123;id'), /Invalid PID/);
    await assert.rejects(api.getHealthDiagnostic('1 0'), /Invalid PID/);
    await assert.rejects(api.getHealthDiagnostic('-1'), /Invalid PID/);
    assert.equal(calls.length, 0);
});
test('health diagnostic passes only validated PIDs and preserves command output', async () => {
    const { api, calls } = service({
        exec: command => command.includes('/sh/diagnose.sh')
            ? { errno: 0, stdout: 'namespace_check_status=0', stderr: '' } : null,
    });
    const result = await api.getHealthDiagnostic('123 456');
    assert.equal(result.status, 0);
    assert.equal(result.output, 'namespace_check_status=0');
    assert.ok(calls.some(command => command.endsWith("'123 456'") === false && command.endsWith('123 456')));
});
test('health diagnostic keeps nonzero status and stderr as actionable evidence', async () => {
    const { api } = service({
        exec: command => command.includes('/sh/diagnose.sh')
            ? { errno: 2, stdout: 'source_check_status=2', stderr: 'reason=manifest_missing' } : null,
    });
    const result = await api.getHealthDiagnostic('');
    assert.equal(result.status, 2);
    assert.equal(result.output, 'source_check_status=2\nreason=manifest_missing');
});

test('certificate subject lookup remains on-device without uploading certificate bytes', async () => {
    const { api, calls, networkCalls } = service({
        exec: cmd => cmd.startsWith('openssl x509 -in ')
            ? { errno: 0, stderr: '', stdout: 'subject=CN=Private Test CA,O=Example\n' } : null,
    });
    assert.equal(await api.getCertName('/data/misc/user/0/cacerts-added/12345678.0'), 'CN=Private Test CA,O=Example');
    assert.equal(networkCalls.length, 0);
    assert.ok(calls.some(cmd => cmd.startsWith('openssl x509 -in ')));
    assert.ok(!calls.some(cmd => cmd.includes('curl ') || cmd.includes('https://')));
});
test('DER certificate subject is handled locally when the PEM parse fails', async () => {
    const { api, calls, networkCalls } = service({
        exec: cmd => cmd.startsWith('openssl x509 -in ')
            ? { errno: 1, stdout: '', stderr: '' }
            : cmd.startsWith('openssl x509 -inform DER ')
                ? { errno: 0, stdout: 'subject=CN=DER CA', stderr: '' } : null,
    });
    assert.equal(await api.getCertName('/data/local/tmp/cert/example.der'), 'CN=DER CA');
    assert.ok(calls.some(cmd => cmd.startsWith('openssl x509 -inform DER ')));
    assert.equal(networkCalls.length, 0);
});
test('unavailable local X509 parser never falls back to a remote certificate service', async () => {
    const { api, networkCalls } = service({
        exec: cmd => cmd.startsWith('openssl x509 ')
            ? { errno: 127, stdout: '', stderr: 'openssl: not found' } : null,
    });
    assert.equal(await api.getCertName('/data/local/tmp/cert/example.pem'), 'Unknown');
    assert.equal(networkCalls.length, 0);
});
