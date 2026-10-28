export const MAX_REPORT_BYTES = 5 * 1024 * 1024;
export const MAX_DURATION_MS = 15 * 60 * 1000;
export const MAX_EVENTS = 20_000;

const EVENT_NAMES = new Set([
  'sampling_started', 'sampling_stopped', 'app_activated', 'app_deactivated',
  'loupe_enabled', 'loupe_disabled', 'loupe_scene_available', 'loupe_scene_unavailable',
  'pointer_tracking_available', 'pointer_tracking_unavailable', 'loupe_pressed',
  'loupe_released', 'loupe_cancelled', 'edr_enabled', 'edr_disabled', 'frame_summary',
]);
const REPORT_KEYS = [
  'schemaVersion', 'sessionID', 'appVersion', 'buildVersion', 'macOSMajor',
  'macOSMinor', 'macOSPatch', 'architecture', 'truncated', 'events',
].sort();
const EVENT_KEYS = ['elapsedMilliseconds', 'name', 'value1', 'value2', 'value3'].sort();
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify(expected);
}

function isIntegerInRange(value, min, max) {
  return Number.isSafeInteger(value) && value >= min && value <= max;
}

export function validateReport(report) {
  if (!exactKeys(report, REPORT_KEYS)) return 'Unexpected report fields';
  if (report.schemaVersion !== 1) return 'Unsupported schema version';
  if (typeof report.sessionID !== 'string' || !UUID_PATTERN.test(report.sessionID)) return 'Invalid session ID';
  if (typeof report.appVersion !== 'string' || report.appVersion.length > 32 || !/^[A-Za-z0-9.+-]+$/.test(report.appVersion)) return 'Invalid app version';
  if (typeof report.buildVersion !== 'string' || report.buildVersion.length > 32 || !/^[A-Za-z0-9.+-]+$/.test(report.buildVersion)) return 'Invalid build version';
  for (const field of ['macOSMajor', 'macOSMinor', 'macOSPatch']) {
    if (!isIntegerInRange(report[field], 0, 99)) return `Invalid ${field}`;
  }
  if (!['arm64', 'x86_64', 'unknown'].includes(report.architecture)) return 'Invalid architecture';
  if (typeof report.truncated !== 'boolean') return 'Invalid truncated flag';
  if (!Array.isArray(report.events) || report.events.length > MAX_EVENTS) return 'Invalid event count';

  for (const event of report.events) {
    if (!exactKeys(event, EVENT_KEYS)) return 'Unexpected event fields';
    if (!isIntegerInRange(event.elapsedMilliseconds, 0, MAX_DURATION_MS)) return 'Invalid event time';
    if (!EVENT_NAMES.has(event.name)) return 'Unknown event name';
    for (const field of ['value1', 'value2', 'value3']) {
      if (!isIntegerInRange(event[field], -1_000_000_000, 1_000_000_000)) return `Invalid ${field}`;
    }
  }
  return null;
}

// FC 3.0 HTTP triggers pass the whole request event as a JSON Buffer.
function normalizeEvent(event) {
  if (typeof event !== 'string' && !Buffer.isBuffer(event)) return event;
  try {
    const parsed = JSON.parse(event.toString('utf8'));
    if (parsed?.requestContext?.http) return parsed;
  } catch {}
  return event;
}

function requestMethod(event) {
  return event?.requestContext?.http?.method ?? event?.httpMethod ?? event?.method ?? '';
}

function requestBody(event) {
  if (typeof event === 'string' || Buffer.isBuffer(event)) return Buffer.from(event);
  if (typeof event?.body === 'string') {
    return Buffer.from(event.body, event.isBase64Encoded ? 'base64' : 'utf8');
  }
  if (event?.body && typeof event.body === 'object') return Buffer.from(JSON.stringify(event.body));
  return Buffer.alloc(0);
}

function response(statusCode, body) {
  return {
    statusCode,
    isBase64Encoded: false,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
    body: JSON.stringify(body),
  };
}

async function createOSSWriter(context, env) {
  const credentials = context?.credentials;
  if (!credentials?.accessKeyId || !credentials?.accessKeySecret || !credentials?.securityToken) {
    throw new Error('Function execution role credentials are unavailable');
  }
  if (!env.OSS_REGION || !env.OSS_BUCKET) throw new Error('OSS configuration is incomplete');
  const { default: OSS } = await import('ali-oss');
  const client = new OSS({
    region: env.OSS_REGION,
    bucket: env.OSS_BUCKET,
    accessKeyId: credentials.accessKeyId,
    accessKeySecret: credentials.accessKeySecret,
    stsToken: credentials.securityToken,
    authorizationV4: true,
    secure: true,
  });
  return {
    put: (key, body) => client.put(key, body, {
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'private, no-store' },
    }),
  };
}

export function createHandler({ storeFactory = createOSSWriter, env = process.env, now = () => new Date() } = {}) {
  return async (rawEvent, context = {}) => {
    const event = normalizeEvent(rawEvent);
    if (requestMethod(event).toUpperCase() !== 'POST') return response(405, { error: 'method_not_allowed' });

    const body = requestBody(event);
    if (body.length === 0) return response(400, { error: 'empty_body' });
    if (body.length > MAX_REPORT_BYTES) return response(413, { error: 'report_too_large' });

    let report;
    try {
      report = JSON.parse(body.toString('utf8'));
    } catch {
      return response(400, { error: 'invalid_json' });
    }
    const validationError = validateReport(report);
    if (validationError) return response(400, { error: 'invalid_report' });

    try {
      const date = now().toISOString().slice(0, 10).replaceAll('-', '/');
      const key = `diagnostics/${date}/${report.sessionID}.json`;
      const writer = await storeFactory(context, env);
      await writer.put(key, Buffer.from(JSON.stringify(report)));
      return response(201, { diagnosticID: report.sessionID });
    } catch {
      return response(503, { error: 'storage_unavailable' });
    }
  };
}

export const handler = createHandler();
