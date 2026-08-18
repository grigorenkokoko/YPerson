import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';

const port = Number.parseInt(process.env.PORT ?? '8080', 10);
const profiles = new Map();
const exchangeTokens = new Map();
const maxBodyBytes = 64 * 1024;

const publicConfig = Object.freeze({
  version: '2026-08-18.1',
  minimumContract: 1,
  maintenance: false,
  features: {
    nearbyExchange: true,
    sponsoredTemplates: true,
    remoteNotifications: true,
  },
  sponsoredTemplates: [
    { id: 'mint-conference', title: 'Mint Conference', accentHex: '#AEEBD3' },
    { id: 'indigo-studio', title: 'Indigo Studio', accentHex: '#4F5FE7' },
  ],
  privacyURL: 'https://example.invalid/yperson/privacy',
  supportURL: 'https://example.invalid/yperson/support',
  moderationCategories: ['spam', 'abusive_content', 'impersonation'],
  analyticsKillSwitch: false,
});

const configJSON = JSON.stringify(publicConfig);
const configETag = `"${createHash('sha256').update(configJSON).digest('hex')}"`;
const operations = new Set(['refresh', 'publishCard', 'claimExchange', 'updatePushToken', 'removePushToken', 'deleteProfile', 'report', 'block']);
const allowedSyncKeys = new Set(['installationID', 'bearer', 'apnsToken', 'operation', 'card', 'exchangeToken', 'moderationCategory']);
const prohibitedKeys = new Set(['contacts', 'addressBook', 'rawPhotos', 'cameraFrames', 'preciseLocation', 'meetingNote', 'biometricData', 'analyticsParameters']);

function send(response, status, payload, headers = {}) {
  const body = typeof payload === 'string' ? payload : JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    ...headers,
  });
  response.end(body);
}

function readJSON(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBodyBytes) {
        reject(Object.assign(new Error('request body exceeds 64 KiB'), { statusCode: 413 }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(Object.assign(new Error('body must be valid JSON'), { statusCode: 400 })); }
    });
    request.on('error', reject);
  });
}

function validateSync(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw Object.assign(new Error('JSON object required'), { statusCode: 400 });
  const unexpected = Object.keys(payload).find((key) => !allowedSyncKeys.has(key));
  if (unexpected) throw Object.assign(new Error(`unsupported sync field: ${unexpected}`), { statusCode: 400 });
  const serialized = JSON.stringify(payload);
  const prohibited = [...prohibitedKeys].find((key) => serialized.includes(`"${key}"`));
  if (prohibited) throw Object.assign(new Error(`prohibited data field: ${prohibited}`), { statusCode: 400 });
  if (typeof payload.installationID !== 'string' || payload.installationID.length < 3 || payload.installationID.length > 128) throw Object.assign(new Error('installationID must be 3-128 characters'), { statusCode: 400 });
  if (!operations.has(payload.operation)) throw Object.assign(new Error('unsupported operation'), { statusCode: 400 });
  if (payload.apnsToken != null && (typeof payload.apnsToken !== 'string' || payload.apnsToken.length > 256)) throw Object.assign(new Error('invalid apnsToken'), { statusCode: 400 });
  if (payload.moderationCategory != null && !publicConfig.moderationCategories.includes(payload.moderationCategory)) throw Object.assign(new Error('invalid moderationCategory'), { statusCode: 400 });
}

function pruneExchangeTokens(now = Date.now()) {
  for (const [token, expiry] of exchangeTokens.entries()) if (expiry <= now) exchangeTokens.delete(token);
}

function applySync(payload) {
  pruneExchangeTokens();
  const existing = profiles.get(payload.installationID) ?? { updateCount: 0, card: null, apnsToken: null, blocked: [] };
  switch (payload.operation) {
    case 'publishCard': existing.card = payload.card ?? null; break;
    case 'claimExchange':
      if (typeof payload.exchangeToken !== 'string' || payload.exchangeToken.length < 8) throw Object.assign(new Error('valid exchangeToken required'), { statusCode: 400 });
      exchangeTokens.set(payload.exchangeToken, Date.now() + 10 * 60 * 1000);
      break;
    case 'updatePushToken': existing.apnsToken = payload.apnsToken ?? null; break;
    case 'removePushToken': existing.apnsToken = null; break;
    case 'deleteProfile': profiles.delete(payload.installationID); return { accepted: true, serverVersion: publicConfig.version, updateCount: 0, message: 'profile deletion accepted; backup purge window is 30 days' };
    case 'report': break;
    case 'block': existing.blocked.push(`blocked-${Date.now()}`); break;
    case 'refresh': break;
  }
  profiles.set(payload.installationID, existing);
  return { accepted: true, serverVersion: publicConfig.version, updateCount: existing.updateCount, message: `${payload.operation} accepted` };
}

const server = http.createServer(async (request, response) => {
  const requestID = randomUUID();
  response.setHeader('X-Request-ID', requestID);
  try {
    const url = new URL(request.url ?? '/', 'http://127.0.0.1');
    if (request.method === 'GET' && url.pathname === '/health') {
      send(response, 200, { status: 'ok', version: publicConfig.version });
      return;
    }
    if (request.method === 'GET' && url.pathname === '/config') {
      if (request.headers['if-none-match'] === configETag) {
        response.writeHead(304, { ETag: configETag, 'Cache-Control': 'public, max-age=60' });
        response.end();
        return;
      }
      send(response, 200, configJSON, { ETag: configETag, 'Cache-Control': 'public, max-age=60' });
      return;
    }
    if (request.method === 'POST' && url.pathname === '/sync') {
      if (!(request.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) throw Object.assign(new Error('Content-Type must be application/json'), { statusCode: 415 });
      const payload = await readJSON(request);
      validateSync(payload);
      send(response, 200, applySync(payload));
      return;
    }
    if (['/health', '/config', '/sync'].includes(url.pathname)) {
      send(response, 405, { error: 'method_not_allowed', requestID }, { Allow: url.pathname === '/sync' ? 'POST' : 'GET' });
      return;
    }
    send(response, 404, { error: 'not_found', requestID });
  } catch (error) {
    const status = Number.isInteger(error.statusCode) ? error.statusCode : 500;
    send(response, status, { error: status === 500 ? 'internal_error' : 'invalid_request', message: error.message, requestID });
  }
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`YPerson backend listening on http://127.0.0.1:${port}\n`);
});

function shutdown() { server.close(() => process.exit(0)); }
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
