import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';

export const defaultData = process.env.SOLO_STUDIO_DATA || path.join(os.homedir(), 'Library/Application Support/Solo Studio/Mix');
const sessionPattern = /^[A-Fa-f0-9]{32}$/;
const requestPattern = /^[A-Fa-f0-9-]{36}$/;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const pick = (obj, keys) => Object.fromEntries(keys.filter(k => obj?.[k] !== undefined).map(k => [k, obj[k]]));

export class Studio {
  constructor(root = defaultData, timeout = 12000) { this.root = path.resolve(root); this.timeout = timeout; }
  async init() {
    for (const folder of ['control', 'control/requests', 'control/responses']) {
      await fs.mkdir(path.join(this.root, folder), { recursive: true, mode: 0o700 });
      await fs.chmod(path.join(this.root, folder), 0o700);
    }
    this.realRoot = await fs.realpath(this.root);
  }
  async safeFile(relative) {
    const candidate = path.resolve(this.root, relative);
    if (!candidate.startsWith(this.root + path.sep)) throw Error('Invalid data path');
    try {
      const real = await fs.realpath(candidate);
      if (real !== path.join(this.realRoot, path.relative(this.root, candidate))) throw Error('Symlinked data is not exposed');
      return real;
    } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  async json(relative) {
    const file = await this.safeFile(relative);
    if (!file) return null;
    if ((await fs.stat(file)).size > 16 * 1024 * 1024) throw Error('Diagnostic JSON exceeds size limit');
    return JSON.parse(await fs.readFile(file, 'utf8'));
  }
  async session(id) {
    if (!sessionPattern.test(id)) throw Error('Invalid session ID');
    if (!await this.safeFile(`sessions/${id}/snapshot.json`)) throw Error('Mix session not found');
    return `sessions/${id}`;
  }
  async studioStatus() {
    const status = await this.json('control/studio.json');
    if (!status) return { online: false, message: 'Open the updated Solo Studio panel in REAPER.' };
    const age = Math.max(0, Date.now() / 1000 - status.updated);
    return { ...status, heartbeat_age_seconds: age, responsive: status.online && age < 5,
      message: !status.online ? 'Solo Studio panel is closed.' : age >= 5 ? 'Panel heartbeat is stale: REAPER may be rendering, blocked by a dialog, or closed.' : 'Connected to Solo Studio.' };
  }
  async listSessions({ limit = 20, project_path } = {}) {
    const entries = await fs.readdir(path.join(this.root, 'sessions')).catch(e => { if (e.code === 'ENOENT') return []; throw e; });
    const sessions = [];
    for (const id of entries.filter(n => sessionPattern.test(n))) {
      try {
        const dir = await this.session(id);
        const snapshot = await this.json(`${dir}/snapshot.json`);
        if (project_path !== undefined && snapshot.project_path !== project_path) continue;
        const state = await this.json(`${dir}/status.json`) || {};
        const stop = await this.json(`${dir}/panel-stop.json`);
        sessions.push({ id, project_path: snapshot.project_path, finished: snapshot.finished, mode: snapshot.mode,
          state: state.state || 'unknown', updated: state.updated || 0, completion_reason: state.completion_reason,
          stop_reason: stop?.reason, stop_message: stop?.message, cost_usd: state.cost_usd });
      } catch (error) { sessions.push({ id, diagnostic_error: error.message, updated: 0 }); }
    }
    sessions.sort((a, b) => b.updated - a.updated);
    return { sessions: sessions.slice(0, limit), total: sessions.length };
  }
  async mixStatus(id) {
    const dir = await this.session(id);
    const state = await this.json(`${dir}/status.json`) || {};
    const snapshot = await this.json(`${dir}/snapshot.json`);
    const worker = await this.json(`${dir}/worker.json`);
    let workerAlive = null;
    if (Number.isSafeInteger(worker?.pid) && worker.pid > 0) {
      try { process.kill(worker.pid, 0); workerAlive = true; } catch (error) { workerAlive = error.code === 'EPERM'; }
    }
    return { session_id: id, project_path: snapshot.project_path, mode: snapshot.mode, finished: snapshot.finished,
      bounds: snapshot.bounds, ...pick(state, ['state', 'updated', 'calls', 'cost_usd', 'completion_reason', 'reference_issues', 'activity', 'failure', 'pass_id', 'measurement_error', 'loudness_goal']),
      worker: worker ? { ...worker, process_alive: workerAlive } : null,
      panel_stop: await this.json(`${dir}/panel-stop.json`),
      measurements: (state.measurements || []).map(p => pick(p, ['title', 'measurement_bounds', 'loudness', 'rms_dbfs'])),
      recent_events: (state.events || []).slice(-12), measurement_timings: (state.measurement_timings || []).slice(-10) };
  }
  async readLog({ session_id, source = 'worker', cursor, limit = 50 }) {
    const dir = await this.session(session_id);
    const filename = source === 'worker' ? 'events.jsonl' : 'bridge-events.jsonl';
    if (!['worker', 'reaper'].includes(source)) throw Error('Unknown log source');
    const file = await this.safeFile(`${dir}/${filename}`);
    if (!file) {
      const state = await this.json(`${dir}/status.json`) || {};
      return { source, events: [], next_cursor: 0, legacy_events: (state.events || []).slice(-limit),
        message: 'This older session has no durable log for this source; only its saved status events are available.' };
    }
    const handle = await fs.open(file, 'r');
    try {
      const size = (await handle.stat()).size;
      if (cursor !== undefined && (!Number.isSafeInteger(cursor) || cursor < 0 || cursor > size)) throw Error('Invalid log cursor');
      const tail = cursor === undefined;
      const start = tail ? Math.max(0, size - 512 * 1024) : cursor;
      const buffer = Buffer.alloc(Math.min(size - start, 512 * 1024));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, start);
      let at = 0;
      if (tail && start > 0) { const n = buffer.indexOf(10); at = n < 0 ? bytesRead : n + 1; }
      const rows = []; let next = start + at;
      while (at < bytesRead && (tail || rows.length < limit)) {
        const end = buffer.indexOf(10, at); if (end < 0) break;
        try { rows.push(JSON.parse(buffer.toString('utf8', at, end))); }
        catch { rows.push({ kind: 'unreadable_log_line', byte_offset: start + at }); }
        at = end + 1; next = start + at;
      }
      return { source, events: tail ? rows.slice(-limit) : rows, next_cursor: next, has_more: next < size, size_bytes: size };
    } finally { await handle.close(); }
  }
  async diagnostics(id) {
    const dir = await this.session(id);
    const request = await this.json(`${dir}/request.json`);
    const response = /^[a-zA-Z0-9-]{1,80}$/.test(request?.id || '') ? await this.json(`${dir}/response-${request.id}.json`) : null;
    return { ...await this.mixStatus(id), studio: await this.studioStatus(),
      config: pick(await this.json(`${dir}/config.json`), ['model', 'direction', 'rounds', 'stop_after_usd', 'bounds', 'references', 'visual_analysis', 'resume', 'target_lufs']),
      failed_measurement: await this.json(`${dir}/failed-measurement.json`), last_bridge_request: request,
      last_bridge_response: response, awaiting_bridge_response: !!request && !response,
      worker_log: await this.readLog({ session_id: id, limit: 15 }),
      reaper_log: await this.readLog({ session_id: id, source: 'reaper', limit: 15 }) };
  }
  async references() {
    const library = await this.json('library.json') || {};
    return { default: library.default || '', references: (library.references || []).map(r => pick(r, ['id', 'title'])) };
  }
  async command(command, { request_id = randomUUID(), ...args }) {
    if (!requestPattern.test(request_id)) throw Error('Invalid request ID');
    const replyPath = `control/responses/${request_id}.json`;
    const prior = await this.json(replyPath);
    // Stable receipts make repeated request IDs safe even after panel reload.
    const ticketPath = `control/${request_id}.json`;
    const previous = await this.json(ticketPath);
    if (previous && (previous.command !== command || JSON.stringify(previous.arguments) !== JSON.stringify(args))) throw Error('Request ID was already used for different arguments');
    if (prior && !prior.executing) return { request_id, ...prior };
    if (prior?.executing) throw Error(`Request ${request_id} was already accepted. Inspect mix status before retrying; it will not be replayed.`);
    const status = await this.studioStatus();
    if (!status.responsive) throw Error(status.message);
    if (args.project_id !== status.project.id) throw Error('Active project differs from project_id; refresh studio status');
    if (previous) throw Error(`Request ${request_id} is pending or expired. Inspect status before issuing a new request.`);
    const request = { id: request_id, command, arguments: args, instance_id: status.instance_id, expires_at: Date.now() / 1000 + this.timeout / 1000 };
    // Exclusive ticket prevents two clients from issuing the same mutation.
    await fs.writeFile(path.join(this.root, ticketPath), JSON.stringify(request), { flag: 'wx', mode: 0o600 });
    const inbox = path.join(this.root, `control/requests/${request_id}.json`);
    await fs.writeFile(inbox + '.tmp', JSON.stringify(request), { mode: 0o600 });
    await fs.rename(inbox + '.tmp', inbox);
    while (Date.now() / 1000 <= request.expires_at + .5) {
      const reply = await this.json(replyPath);
      if (reply && !reply.executing) return { request_id, ...reply };
      await pause(100);
    }
    // An expired command is rejected in REAPER, including after a long render.
    throw Error(`REAPER did not acknowledge request ${request_id}. It expires automatically. Check status/logs before retrying; do not blindly start another paid pass.`);
  }
}
