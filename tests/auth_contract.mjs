// node tests/auth_contract.mjs /path/to/fudai-auth
// Uses an in-memory database and a test-only key; never touches deployed devices.
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHmac } from 'node:crypto';
const root = resolve(process.argv[2]);
const { handleCheck } = await import(pathToFileURL(resolve(root, 'src/api.js')));
const db = new DatabaseSync(':memory:');
db.exec(readFileSync(resolve(root, 'schema.sql'), 'utf8'));
const env = { LICENSE_SECRET: 'test-only-key', DB: { prepare(sql) {
    const stmt = db.prepare(sql);
    return { bind(...args) { return {
        async first() { return stmt.get(...args) ?? null; },
        async run() { return stmt.run(...args); },
    }; } };
} } };
const udid = 'SPARKS-TEST-DEVICE';
async function check(expected, device = udid) {
    const response = await handleCheck(new Request('https://test.invalid/api/v1/check', {
        method: 'POST', body: JSON.stringify({ udid: device, product: 'sparks', version: 'test', fmt: 2 }),
    }), env);
    assert.equal(response.status, 200);
    const j = await response.json();
    assert.equal(j.status, expected);
    assert.match(j.code, /^SPK-/);
    const payload = `FA1|${device}|sparks|${j.status}|${j.nick}|${j.code}|${j.expires_at ?? 0}|${j.now}`;
    assert.equal(createHmac('sha256', env.LICENSE_SECRET).update(payload).digest('hex'), j.sig);
    console.log(`${expected}: fmt=2 signature and ID verified`);
}
await check('pending');
db.prepare("UPDATE devices SET status='active'").run();
await check('ok');
db.prepare("UPDATE devices SET expires_at=?").run(Math.floor(Date.now()/1000) + 3600);
await check('ok');
db.prepare("UPDATE devices SET expires_at=1").run();
await check('expired');
db.prepare("UPDATE devices SET status='blocked'").run();
await check('blocked');
db.prepare("UPDATE devices SET status='pending', expires_at=NULL").run();
await check('pending');
assert.equal(db.prepare('SELECT COUNT(*) AS n FROM devices').get().n, 1);
console.log('All 6 backend state transitions passed; repeated checks keep one device.');

// IDFV and locally generated UUIDs use the same UUID format.
const fallbackID = '67F88645-13B3-4A5D-A8A2-9A78FE04265D';
await check('pending', fallbackID);
await check('pending', fallbackID);
assert.equal(db.prepare('SELECT COUNT(*) AS n FROM devices').get().n, 2);
console.log('UUID fallback accepted; repeat registration retains the same device.');
