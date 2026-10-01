// Driven only by Tests/Run MCP checks.lua in a disposable synthetic project.
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const data = process.argv[2];
const client = new Client({ name: 'solo-studio-native-check', version: '1' });
const transport = new StdioClientTransport({ command: process.execPath,
  args: [fileURLToPath(new URL('./server.mjs', import.meta.url))], env: { ...process.env, SOLO_STUDIO_DATA: data }, stderr: 'pipe' });
let checks = 0;
async function call(name, args = {}) {
  const reply = await client.callTool({ name, arguments: args });
  if (reply.isError) throw Error(JSON.stringify(reply.content));
  return reply.structuredContent;
}
async function until(fn) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 200)); }
  throw Error('Timed out waiting for native mix state');
}
async function waiting(session_id) {
  const s = await call('get_mix_status', { session_id });
  return s.worker?.active && s.pass_id === s.worker.pass_id && s.activity?.name === 'openrouter_request';
}
try {
  await client.connect(transport);
  const state = await until(async () => { const s = await call('get_studio_status'); return s.responsive && s; });
  const args = { request_id: randomUUID(), project_id: state.project.id, bounds: [0, 8], rounds: 2, visual_analysis: false, references: [] };
  const started = await call('start_mix', args); const session_id = started.result.session_id;
  assert.match(session_id, /^[A-F0-9]{32}$/i); checks++;
  const same = await call('start_mix', args); assert.equal(same.result.session_id, session_id); checks++;
  await until(async () => { const s = await call('get_mix_status', { session_id }); return s.state === 'review' && s.worker?.active === false; }); checks++;
  let log = await call('read_mix_log', { session_id, source: 'worker', cursor: 0, limit: 100 });
  assert(log.events.some(e => e.kind === 'pass_finished')); checks++;
  log = await call('read_mix_log', { session_id, source: 'reaper', cursor: 0, limit: 100 });
  assert(log.events.some(e => e.kind === 'render_started')); checks++;
  await call('resume_mix', { project_id: state.project.id, session_id, rounds: 2 });
  await until(() => waiting(session_id));
  await fs.writeFile(path.join(data, 'inject-guard'), '1');
  const stopped = await until(async () => { const s = await call('get_mix_diagnostics', { session_id }); return s.panel_stop && s.worker?.active === false && s; });
  assert.equal(stopped.panel_stop.reason, 'guard_rejected');
  assert.equal(stopped.panel_stop.context.transport, 1);
  assert.match(stopped.panel_stop.message, /Stop playback/); checks++;
  await fs.writeFile(path.join(data, 'release-guard'), '1');
  await until(async () => (await call('get_studio_status')).transport === 0);
  await call('resume_mix', { project_id: state.project.id, session_id, rounds: 2 });
  await until(() => waiting(session_id));
  await call('cancel_mix', { project_id: state.project.id, session_id });
  const cancelled = await until(async () => { const s = await call('get_mix_status', { session_id }); return s.state === 'cancelled' && s.worker?.active === false && s; });
  assert.equal(cancelled.finished, false); assert.equal(cancelled.mode, 'candidate'); checks++;
  const sessions = await call('list_mix_sessions'); assert.equal(sessions.total, 1); checks++;
  await fs.writeFile(path.join(data, 'test-result.json'), JSON.stringify({ ok: true, checks, session_id }));
} catch (error) {
  await fs.writeFile(path.join(data, 'test-result.json'), JSON.stringify({ error: error.stack, checks }));
} finally { await client.close(); }
