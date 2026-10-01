import test from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { Studio } from './studio.mjs';

const id = 'A'.repeat(32);
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'solo-mcp-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const studio = new Studio(root, 250); await studio.init();
  const write = async (relative, data) => {
    const dest = path.join(root, relative); await fs.mkdir(path.dirname(dest), { recursive: true });
    await fs.writeFile(dest, JSON.stringify(data));
  };
  await write('control/studio.json', { online: true, updated: Date.now() / 1000, instance_id: 'instance', project: { id: 'project' }, mix: {} });
  await write(`sessions/${id}/snapshot.json`, { project_path: '/test/song.rpp', bounds: [0, 8], finished: false });
  await write(`sessions/${id}/status.json`, { state: 'error', updated: 123, events: [{ text: 'Stopped' }], failure: { message: 'Silent render' } });
  return { root, studio, write };
}

test('status and diagnostics distinguish panel guard and worker failure', async t => {
  const { studio, write } = await fixture(t);
  await write(`sessions/${id}/panel-stop.json`, { reason: 'guard_rejected', message: 'Stop playback', context: { transport: 1 } });
  const status = await studio.diagnostics(id);
  assert.equal(status.panel_stop.context.transport, 1);
  assert.equal(status.failure.message, 'Silent render');
  assert.equal(status.worker_log.legacy_events[0].text, 'Stopped');
  assert.equal((await studio.listSessions()).sessions[0].stop_reason, 'guard_rejected');
});

test('log cursors preserve UTF-8 and leave an incomplete append unread', async t => {
  const { studio, root } = await fixture(t);
  const file = path.join(root, `sessions/${id}/events.jsonl`);
  const first = JSON.stringify({ text: 'guitár 🎸' }) + '\n';
  await fs.writeFile(file, first + '{"text":"next');
  const a = await studio.readLog({ session_id: id, cursor: 0 });
  assert.equal(a.events[0].text, 'guitár 🎸'); assert.equal(a.next_cursor, Buffer.byteLength(first));
  await fs.appendFile(file, '"}\n');
  const b = await studio.readLog({ session_id: id, cursor: a.next_cursor });
  assert.deepEqual(b.events, [{ text: 'next' }]); assert.equal(b.has_more, false);
});

test('session IDs and symlinks cannot expose credentials or arbitrary files', async t => {
  const { studio, root, write } = await fixture(t);
  await assert.rejects(studio.mixStatus('../credentials'), /Invalid session/);
  await write('credentials.json', { api_key: 'private-test-secret' });
  await fs.symlink(path.join(root, 'credentials.json'), path.join(root, `sessions/${id}/events.jsonl`));
  await assert.rejects(studio.readLog({ session_id: id }), /Symlinked/);
  assert.equal(JSON.stringify(await studio.references()).includes('private-test-secret'), false);
});

test('commands require a fresh heartbeat and the exact active project', async t => {
  const { studio, write, root } = await fixture(t);
  await assert.rejects(studio.command('start_mix', { project_id: 'wrong' }), /differs/);
  await write('control/studio.json', { online: true, updated: 1, project: { id: 'project' } });
  await assert.rejects(studio.command('start_mix', { project_id: 'project' }), /stale/);
  assert.deepEqual(await fs.readdir(path.join(root, 'control/requests')), []);
});

test('completed command receipt is idempotent and rejects changed arguments', async t => {
  const { studio, root, write } = await fixture(t);
  const request_id = randomUUID();
  const timer = setInterval(async () => {
    try {
      const request = JSON.parse(await fs.readFile(path.join(root, `control/requests/${request_id}.json`)));
      assert.equal(request.arguments.project_id, 'project');
      await write(`control/responses/${request_id}.json`, { result: { session_id: id } });
    } catch {}
  }, 20); t.after(() => clearInterval(timer));
  const args = { request_id, project_id: 'project' };
  const result = await studio.command('start_mix', args);
  assert.equal(result.result.session_id, id);
  assert.deepEqual(await studio.command('start_mix', args), result);
  await assert.rejects(studio.command('start_mix', { ...args, rounds: 3 }), /different arguments/);
});

test('expired and ambiguous commands are never silently reissued', async t => {
  const { studio, root, write } = await fixture(t);
  const request_id = randomUUID(); const args = { request_id, project_id: 'project' };
  await assert.rejects(studio.command('start_mix', args), /expires automatically/);
  const file = path.join(root, `control/requests/${request_id}.json`);
  const before = await fs.readFile(file, 'utf8');
  await assert.rejects(studio.command('start_mix', args), /pending or expired/);
  assert.equal(await fs.readFile(file, 'utf8'), before);
  await write(`control/responses/${request_id}.json`, { executing: true });
  await assert.rejects(studio.command('start_mix', args), /will not be replayed/);
});

test('real MCP stdio handshake, schemas, status, logs and diagnostics', async t => {
  const { root } = await fixture(t);
  const transport = new StdioClientTransport({ command: process.execPath,
    args: [fileURLToPath(new URL('./server.mjs', import.meta.url))], env: { ...process.env, SOLO_STUDIO_DATA: root }, stderr: 'pipe' });
  const client = new Client({ name: 'solo-studio-test', version: '1' });
  await client.connect(transport); t.after(() => client.close());
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 9);
  assert.equal(tools.find(t => t.name === 'start_mix').annotations.readOnlyHint, false);
  assert.equal(tools.find(t => t.name === 'read_mix_log').annotations.readOnlyHint, true);
  const state = await client.callTool({ name: 'get_studio_status', arguments: {} });
  assert.equal(state.structuredContent.project.id, 'project');
  const diagnostic = await client.callTool({ name: 'get_mix_diagnostics', arguments: { session_id: id } });
  assert.equal(diagnostic.structuredContent.failure.message, 'Silent render');
  const bad = await client.callTool({ name: 'start_mix', arguments: { project_id: 'project', rounds: 101 } });
  assert.equal(bad.isError, true);
});
