// Public test CAs only. Private keys are ephemeral and never written to disk.
import { generateKeyPairSync, sign, createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
const dir = new URL('./fixtures/', import.meta.url);
mkdirSync(dir, { recursive: true });
const der = (tag, ...parts) => {
    const body = Buffer.concat(parts.map(p => Buffer.isBuffer(p) ? p : Buffer.from(p)));
    let size = Buffer.from([body.length]);
    if (body.length >= 128) {
        const bytes = [];
        for (let n = body.length; n; n >>= 8) bytes.unshift(n & 255);
        size = Buffer.from([128 | bytes.length, ...bytes]);
    }
    return Buffer.concat([Buffer.from([tag]), size, body]);
};
const seq = (...p) => der(0x30, ...p);
const oid = hex => der(6, Buffer.from(hex, 'hex'));
const algorithm = seq(oid('2a864886f70d01010b'), der(5, []));
const name = seq(der(0x31, seq(oid('550403'), der(12, Buffer.from('MoveCertificate Test CA')))));
const hash = createHash('md5').update(name).digest().readUInt32LE().toString(16).padStart(8, '0');
for (const [file, serial] of [['native', 1], ['collision', 2]]) {
    const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const tbs = seq(der(0xa0, der(2, [2])), der(2, [serial]), algorithm, name,
        seq(der(23, Buffer.from('250101000000Z')), der(23, Buffer.from('350101000000Z'))), name,
        publicKey.export({ type: 'spki', format: 'der' }),
        der(0xa3, seq(seq(oid('551d13'), der(1, [255]), der(4, seq(der(1, [255])))))));
    const cert = seq(tbs, algorithm, der(3, Buffer.concat([Buffer.from([0]), sign('sha256', tbs, privateKey)])));
    const base64 = cert.toString('base64');
    writeFileSync(new URL(`${file}.pem`, dir), `-----BEGIN CERTIFICATE-----\n${base64.match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`);
    writeFileSync(new URL(`${file}.b64`, dir), base64 + '\n');
}
writeFileSync(new URL('subject-hash.txt', dir), hash + '\n');
