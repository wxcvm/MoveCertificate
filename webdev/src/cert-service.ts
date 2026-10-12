import { exec } from 'kernelsu';
import {
    MODULE_DIR, CERT_HIGH_SYSTEM, CERT_LOW_SYSTEM, CERT_MODULE, MODULE_PROP_PATH,
    INSTALL_LOG_PATH, MODE_CONF_PATH, CERT_NAME_CACHE_PATH, CERT_QUERY_API,
    MANIFEST_PATH, RUNTIME_PATH, STATE_BOOT_PATH, SELECTION_PATH,
} from './constants.js';
import type { RunMode, CertEntry, CertStatus, RuntimeInfo } from './constants.js';

interface ExecResult { errno: number; stdout: string; stderr: string; }
const quote = (value: string): string => `'${value.split("'").join("'\\''")}'`;
async function run(command: string): Promise<string> {
    const result = await exec(command) as ExecResult;
    if (result.errno !== 0) throw new Error(result.stderr.trim() || `命令执行失败 (${result.errno})`);
    return String(result.stdout).trim();
}
async function optionalFile(path: string): Promise<string | null> {
    // Missing files are normal before the first boot; permission errors are not.
    const result = await exec(`if [ ! -e ${quote(path)} ]; then printf '__MISSING__'; else cat ${quote(path)}; fi`) as ExecResult;
    if (result.errno !== 0) throw new Error(`读取文件失败: ${path}`);
    const output = String(result.stdout).trim();
    return output === '__MISSING__' ? null : output;
}
export async function getFileList(path: string): Promise<string[]> {
    return (await run(`ls -1 ${quote(path)}`)).split('\n').filter(Boolean);
}
export async function readFileBase64(path: string): Promise<string> {
    // Redirection fails before base64 starts when the source is unreadable.
    return run(`base64 < ${quote(path)}`);
}
async function readCache(): Promise<Record<string, string>> {
    const data = await optionalFile(CERT_NAME_CACHE_PATH);
    if (!data) return {};
    try {
        const parsed: unknown = JSON.parse(data);
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
        return Object.fromEntries(Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === 'string'));
    } catch { return {}; }
}
let cacheWrites = Promise.resolve();
function saveName(fingerprint: string, name: string): void {
    cacheWrites = cacheWrites.then(async () => {
        const cache = await readCache();
        cache[fingerprint] = name;
        const bytes = new TextEncoder().encode(JSON.stringify(cache));
        const data = btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(''));
        const suffix = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
        const temporary = `${CERT_NAME_CACHE_PATH}.webui-${suffix}.tmp`;
        try {
            await run(`printf '%s' ${quote(data)} | base64 -d > ${quote(temporary)} && chmod 600 ${quote(temporary)} && mv ${quote(temporary)} ${quote(CERT_NAME_CACHE_PATH)}`);
        } finally {
            await run(`rm -f ${quote(temporary)}`);
        }
    }).catch(error => console.error('写入证书名称缓存失败:', error));
}
export async function getCertName(path: string, fingerprint?: string): Promise<string> {
    // Legacy subject-hash entries cannot identify a renewed or colliding CA.
    if (fingerprint) {
        const cache = await readCache();
        if (cache[fingerprint]) return cache[fingerprint];
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
        const data = await readFileBase64(path);
        const response = await fetch(CERT_QUERY_API, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: 'cert base64', data }), signal: controller.signal,
        });
        if (!response.ok) return 'Unknown';
        const result: unknown = await response.json();
        if (!result || typeof result !== 'object' || !('result' in result) || typeof result.result !== 'string') return 'Unknown';
        if (fingerprint) saveName(fingerprint, result.result);
        return result.result;
    } catch { return 'Unknown'; } finally { clearTimeout(timer); }
}
export async function getRuntimeInfo(): Promise<RuntimeInfo> {
    const sdk = Number(await run('getprop ro.build.version.sdk'));
    if (!Number.isInteger(sdk) || sdk < 24) throw new Error('获取系统版本失败');
    const bootId = await run('cat /proc/sys/kernel/random/boot_id');
    const data = await optionalFile(RUNTIME_PATH);
    const values = Object.fromEntries((data ?? '').split('\n').map(line => {
        const position = line.indexOf('=');
        return position < 0 ? [line, ''] : [line.slice(0, position), line.slice(position + 1)];
    }));
    const current = values.boot_id === bootId;
    const mode = current ? values.effective_mode : null;
    return {
        sdk, bootId, effectiveMode: mode === 'builtin' || mode === 'compatible' ? mode : null,
        state: current ? values.state ?? 'unknown' : 'unknown',
        reason: current ? values.reason ?? 'none' : 'no_current_boot_status',
        modeReason: current ? values.mode_reason ?? 'none' : 'none',
    };
}
interface SourceRow { fingerprint: string; target: string; source: string; state: string; }
function parseManifest(data: string): SourceRow[] {
    return data.split('\n').filter(Boolean).map(line => {
        const [fingerprint, target, source, state] = line.split('\t');
        if (!fingerprint || !/^[0-9a-f]{64}$/.test(fingerprint) || !target ||
            (target !== '-' && !/^[0-9a-f]{8}\.[0-9]+$/.test(target)) || !source ||
            !/^\/data\/misc\/user\/\d+\/cacerts-added\/[0-9a-f]{8}\.\d+$|^\/data\/local\/tmp\/cert\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(source) ||
            !state || !['pending', 'excluded', 'disabled', 'native', 'unverified', 'removed'].includes(state)) {
            throw new Error('证书来源记录损坏，请重启后重试');
        }
        return { fingerprint, target, source, state };
    });
}
export async function getInstallCertResults(): Promise<CertEntry[]> {
    const runtime = await getRuntimeInfo();
    const [stateBoot, data] = await Promise.all([optionalFile(STATE_BOOT_PATH), optionalFile(MANIFEST_PATH)]);
    if (stateBoot !== runtime.bootId || data === null) {
        // Show every user's inputs while making unavailable boot verification explicit.
        const inputList = await run("for d in /data/misc/user/*/cacerts-added; do [ ! -d \"$d\" ] || find \"$d\" -maxdepth 1 -type f; done");
        return inputList.split('\n').filter(path => /\/cacerts-added\/[0-9a-f]{8}\.\d+$/.test(path)).map(path => ({
            id: '', filename: path.split('/').pop()!, name: path.split('/').pop()!,
            status: 'unknown', sources: [path], canDelete: false, enabled: false, canToggle: false, pendingChange: false,
        }));
    }
    const grouped = new Map<string, SourceRow[]>();
    const selections = await readSelections();
    for (const row of parseManifest(data)) grouped.set(row.fingerprint, [...grouped.get(row.fingerprint) ?? [], row]);
    const system = runtime.sdk >= 34 ? CERT_HIGH_SYSTEM : CERT_LOW_SYSTEM;
    return Promise.all(Array.from(grouped, async ([fingerprint, rows]): Promise<CertEntry> => {
        const row = rows.find(item => item.state === 'pending') ?? rows[0]!;
        const filename = row.target === '-' ? row.source.split('/').pop()! : row.target;
        let status: CertStatus;
        if (row.state === 'removed') status = 'removed';
        else if (row.state === 'excluded') status = 'excluded';
        else if (row.state === 'disabled') status = 'disabled';
        else if (row.state === 'native') status = 'native';
        else if (row.state === 'unverified') status = 'unverified';
        else if (runtime.state !== 'ready') status = runtime.state === 'failed' ? 'failed' : 'unknown';
        else {
            const result = await exec(`test -r ${quote(CERT_MODULE + row.target)} && test -r ${quote(system + row.target)} && cmp -s ${quote(CERT_MODULE + row.target)} ${quote(system + row.target)}`) as ExecResult;
            status = result.errno === 0 ? 'success' : 'failed';
        }
        const path = row.state === 'pending' || row.state === 'native' ? CERT_MODULE + row.target : row.source;
        const name = row.state === 'removed' ? filename : `${filename}: ${await getCertName(path, fingerprint)}`;
        const canToggle = ['pending', 'disabled', 'excluded'].includes(row.state);
        const bootEnabled = row.state === 'pending';
        const enabled = canToggle ? selections.get(fingerprint) ?? bootEnabled : false;
        return { id: fingerprint, filename, status, name, sources: rows.map(item => item.source),
            canDelete: row.state !== 'removed', enabled, canToggle, pendingChange: canToggle && enabled !== bootEnabled };
    }));
}
async function readSelections(): Promise<Map<string, boolean>> {
    const data = await optionalFile(SELECTION_PATH);
    const selections = new Map<string, boolean>();
    for (const line of (data ?? '').split('\n').filter(Boolean)) {
        const match = /^([0-9a-f]{64})\t([01])$/.exec(line);
        if (!match) throw new Error('证书挂载选择配置损坏');
        selections.set(match[1]!, match[2] === '1');
    }
    return selections;
}
export async function setCertEnabled(fingerprint: string, enabled: boolean): Promise<void> {
    if (!/^[0-9a-f]{64}$/.test(fingerprint) || typeof enabled !== 'boolean') throw new Error('非法的证书挂载选择');
    await run(`sh ${quote(`${MODULE_DIR}/sh/set-cert-enabled.sh`)} ${quote(fingerprint)} ${enabled ? '1' : '0'}`);
    if ((await readSelections()).get(fingerprint) !== enabled) throw new Error('证书挂载选择写入校验失败');
}
export async function deleteCert(fingerprint: string): Promise<void> {
    if (!/^[0-9a-f]{64}$/.test(fingerprint)) throw new Error('非法的证书指纹');
    await run(`sh ${quote(`${MODULE_DIR}/sh/delete-cert.sh`)} ${quote(fingerprint)}`);
}
export async function getVersionInfo(): Promise<string[]> {
    return (await run(`cat ${quote(MODULE_PROP_PATH)}`)).split('\n');
}
export async function getLoggerInfo(): Promise<string[]> {
    return (await optionalFile(INSTALL_LOG_PATH) ?? '').split('\n').filter(Boolean);
}
export async function getCurrentMode(): Promise<RunMode> {
    const data = await optionalFile(MODE_CONF_PATH);
    const match = /^\s*mode\s*=\s*(compatible|builtin)\s*$/m.exec(data ?? '');
    return match?.[1] === 'builtin' ? 'builtin' : 'compatible';
}
export async function setMode(mode: RunMode): Promise<void> {
    if (mode !== 'compatible' && mode !== 'builtin') throw new Error('非法的运行模式');
    await run(`sh ${quote(`${MODULE_DIR}/sh/set-mode.sh`)} ${quote(mode)}`);
    if (await getCurrentMode() !== mode) throw new Error('模式配置写入校验失败');
}
