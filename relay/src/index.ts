// Approve Gate relay on Cloudflare: the part of the ntfy protocol Approve Gate uses.
//   POST /<topic>                        store a message (ciphertext from the Mac or the phone)
//   GET  /<topic>/json?since=<time|id>   stream messages as JSON lines; add poll=1 to get them and close
// One Durable Object per topic keeps the last 15 minutes. Only Approve Gate topic names
// (ag- plus 32 hex characters) are accepted, so it is not a general-purpose relay.
import { DurableObject } from "cloudflare:workers";

const TOPIC = /^ag-[0-9a-f]{32}$/;
const KEEP_SECONDS = 15 * 60;
const MAX_BODY = 16 * 1024;
const NDJSON = { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" };
const enc = new TextEncoder();

interface Env {
  TOPICS: DurableObjectNamespace<Topic>;
}

type Row = { seq: number; time: number; body: string };

export class Topic extends DurableObject<Env> {
  private listeners = new Set<WritableStreamDefaultWriter<Uint8Array>>();
  private keepalive: ReturnType<typeof setInterval> | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS m (seq INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER, body TEXT)");
  }

  private line(topic: string, r: Row): Uint8Array {
    return enc.encode(JSON.stringify({ id: `m${r.seq}`, time: r.time, event: "message", topic, message: r.body }) + "\n");
  }

  private send(w: WritableStreamDefaultWriter<Uint8Array>, data: Uint8Array) {
    w.write(data).catch(() => this.drop(w));
  }

  private drop(w: WritableStreamDefaultWriter<Uint8Array>) {
    this.listeners.delete(w);
    if (this.listeners.size === 0 && this.keepalive) {
      clearInterval(this.keepalive);
      this.keepalive = undefined;
    }
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const topic = url.pathname.split("/")[1];
    const now = Math.floor(Date.now() / 1000);
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM m WHERE time < ?", now - KEEP_SECONDS);

    if (req.method === "POST") {
      const body = await req.text();
      if (body.length > MAX_BODY) return new Response("message too large\n", { status: 413 });
      const seq = sql.exec<{ seq: number }>("INSERT INTO m (time, body) VALUES (?, ?) RETURNING seq", now, body).one().seq;
      const row = { seq, time: now, body };
      const data = this.line(topic, row);
      for (const w of this.listeners) this.send(w, data);
      return Response.json({ id: `m${seq}`, time: now, event: "message", topic });
    }

    const since = url.searchParams.get("since") ?? String(now);
    const rows = /^\d+$/.test(since)
      ? sql.exec<Row>("SELECT seq, time, body FROM m WHERE time >= ? ORDER BY seq", Number(since)).toArray()
      : /^m\d+$/.test(since)
        ? sql.exec<Row>("SELECT seq, time, body FROM m WHERE seq > ? ORDER BY seq", Number(since.slice(1))).toArray()
        : sql.exec<Row>("SELECT seq, time, body FROM m ORDER BY seq").toArray();

    if (url.searchParams.get("poll") === "1") {
      const out = rows.map((r) => JSON.stringify({ id: `m${r.seq}`, time: r.time, event: "message", topic, message: r.body })).join("\n");
      return new Response(out ? out + "\n" : "", { headers: NDJSON });
    }

    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const w = writable.getWriter();
    this.send(w, enc.encode(JSON.stringify({ event: "open", topic }) + "\n"));
    for (const r of rows) this.send(w, this.line(topic, r));
    this.listeners.add(w);
    req.signal.addEventListener("abort", () => this.drop(w));
    // Clients time out after 90 s of silence; ntfy sends a keepalive every 45 s.
    this.keepalive ??= setInterval(() => {
      const ka = enc.encode(JSON.stringify({ event: "keepalive", time: Math.floor(Date.now() / 1000) }) + "\n");
      for (const l of this.listeners) this.send(l, ka);
    }, 30_000);
    return new Response(readable, { headers: NDJSON });
  }
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const parts = new URL(req.url).pathname.split("/").filter(Boolean);
    const topic = parts[0] ?? "";
    const ok = TOPIC.test(topic)
      && ((req.method === "POST" && parts.length === 1) || (req.method === "GET" && parts.length === 2 && parts[1] === "json"));
    if (!ok) return new Response("Approve Gate relay\n", { status: 404 });
    return env.TOPICS.get(env.TOPICS.idFromName(topic)).fetch(req);
  },
};
