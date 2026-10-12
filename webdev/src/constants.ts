/** Paths are kept in one place; runtime state is rebuilt for each boot. */
export const MODULE_DIR = '/data/adb/modules/MoveCertificate';
export const CERT_LOW_SYSTEM = '/system/etc/security/cacerts/';
export const CERT_HIGH_SYSTEM = '/apex/com.android.conscrypt/cacerts/';
export const CERT_USER_SYSTEM = '/data/misc/user/0/cacerts-added/';
export const CERT_MODULE = `${MODULE_DIR}/state/certs/`;
export const MODULE_PROP_PATH = `${MODULE_DIR}/module.prop`;
export const INSTALL_LOG_PATH = `${MODULE_DIR}/install.log`;
export const MODE_CONF_PATH = `${MODULE_DIR}/mode.conf`;
export const CERT_NAME_CACHE_PATH = `${MODULE_DIR}/cert_names.json`;
export const MANIFEST_PATH = `${MODULE_DIR}/state/certificate-sources.tsv`;
export const RUNTIME_PATH = `${MODULE_DIR}/runtime.conf`;
export const STATE_BOOT_PATH = `${MODULE_DIR}/state/boot_id`;
export const CERT_QUERY_API = 'https://cert.ys1231.cn/query';
export type RunMode = 'compatible' | 'builtin';
export type CertStatus = 'success' | 'failed' | 'excluded' | 'unverified' | 'removed' | 'unknown';
export interface RuntimeInfo {
    sdk: number;
    bootId: string;
    effectiveMode: RunMode | null;
    state: string;
    reason: string;
    modeReason: string;
}
export interface CertEntry {
    id: string;
    filename: string;
    status: CertStatus;
    name: string;
    sources: string[];
    canDelete: boolean;
}
