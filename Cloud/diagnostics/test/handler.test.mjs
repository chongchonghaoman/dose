import assert from 'node:assert/strict';
import test from 'node:test';
import { createHandler, MAX_REPORT_BYTES, validateReport } from '../index.mjs';

const sessionID = '123e4567-e89b-12d3-a456-426614174000';
const report = () => ({
  schemaVersion: 1,
  sessionID,
  appVersion: '0.1.112',
  buildVersion: '112',
  macOSMajor: 15,
  macOSMinor: 1,
  macOSPatch: 0,
  architecture: 'arm64',
  truncated: false,
  events: [{ elapsedMilliseconds: 10, name: 'loupe_enabled', value1: 0, value2: 0, value3: 0 }],
});
const post = (body) => ({ method: 'POST', headers: { 'content-type': 'application/json' }, body });

test('rejects methods other than POST without touching storage', async () => {
  let writes = 0;
  const handler = createHandler({ storeFactory: () => ({ put: async () => { writes += 1; } }) });
  const result = await handler({ method: 'GET' });
  assert.equal(result.statusCode, 405);
  assert.equal(writes, 0);
});

test('rejects malformed and schema-invalid reports', async () => {
  const handler = createHandler({ storeFactory: () => ({ put: async () => assert.fail('unexpected write') }) });
  assert.equal((await handler(post('{'))).statusCode, 400);
  const invalid = report();
  invalid.machineName = 'private';
  assert.equal((await handler(post(JSON.stringify(invalid)))).statusCode, 400);
});

test('rejects requests larger than five megabytes before parsing or writing', async () => {
  let writes = 0;
  const handler = createHandler({ storeFactory: () => ({ put: async () => { writes += 1; } }) });
  const result = await handler(post(Buffer.alloc(MAX_REPORT_BYTES + 1)));
  assert.equal(result.statusCode, 413);
  assert.equal(writes, 0);
});

test('stores validated reports under a private diagnostic key and returns its ID', async () => {
  let saved;
  const handler = createHandler({
    storeFactory: () => ({ put: async (key, data) => { saved = { key, data: data.toString() }; } }),
    now: () => new Date('2026-10-28T12:34:56.000Z'),
  });
  const result = await handler({
    requestContext: { http: { method: 'POST' } },
    body: JSON.stringify(report()),
  });
  assert.equal(result.statusCode, 201);
  assert.equal(JSON.parse(result.body).diagnosticID, sessionID);
  assert.equal(saved.key, `diagnostics/2026/10/28/${sessionID}.json`);
  assert.deepEqual(JSON.parse(saved.data), report());
});

test('accepts FC 3.0 HTTP trigger events delivered as a JSON Buffer', async () => {
  let saved;
  const handler = createHandler({ storeFactory: () => ({ put: async (key) => { saved = key; } }) });
  const fcEvent = (method, body) => Buffer.from(JSON.stringify({
    requestContext: { http: { method } },
    isBase64Encoded: true,
    body: Buffer.from(body).toString('base64'),
  }));
  assert.equal((await handler(fcEvent('GET', ''))).statusCode, 405);
  assert.equal((await handler(fcEvent('POST', JSON.stringify(report())))).statusCode, 201);
  assert.match(saved, new RegExp(`^diagnostics/\\d{4}/\\d{2}/\\d{2}/${sessionID}\\.json$`));
});

test('accepts schema 1 and 2 reports with frame unit events and rejects unknown schemas', () => {
  const v2 = report();
  v2.schemaVersion = 2;
  v2.events.push({ elapsedMilliseconds: 20, name: 'frame_submit_summary', value1: 60, value2: 120, value3: 0 });
  v2.events.push({ elapsedMilliseconds: 30, name: 'frame_complete_summary', value1: 60, value2: 120, value3: 1800 });
  assert.equal(validateReport(v2), null);
  assert.equal(validateReport(report()), null);
  const v3 = report();
  v3.schemaVersion = 3;
  assert.equal(validateReport(v3), 'Unsupported schema version');
});

test('rejects unapproved event names and arbitrary string values', () => {
  const invalidName = report();
  invalidName.events[0].name = 'pointer_at_100_200';
  assert.equal(validateReport(invalidName), 'Unknown event name');
  const invalidValue = report();
  invalidValue.events[0].value1 = '/Users/person/photo.jpg';
  assert.equal(validateReport(invalidValue), 'Invalid value1');
});
