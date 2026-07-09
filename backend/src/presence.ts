import { DurableObject } from "cloudflare:workers";

export type PresenceStatus = "online" | "solo" | "versus";

interface Attachment {
  uid: string;
  status: PresenceStatus;
}

const MAX_MESSAGE_BYTES = 4 * 1024;

/**
 * Single global presence hub: one WebSocket per signed-in player while the
 * app is open (the Worker verifies the token and passes the uid in). Tracks
 * a coarse status per socket and forwards 1v1 invites between online
 * players. Invite state itself is client-side (expiry, room creation) — the
 * DO is a pure message router, mirroring the room relay philosophy.
 */
export class PresenceDO extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'),
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/ws") {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const uid = request.headers.get("X-Uid");
      if (uid === null || uid === "") {
        return new Response("missing uid", { status: 400 });
      }
      return this.acceptSocket(uid);
    }

    if (url.pathname === "/query" && request.method === "POST") {
      const { uids } = (await request.json()) as { uids?: unknown };
      if (!Array.isArray(uids)) {
        return new Response("bad uids", { status: 400 });
      }
      const statuses: Record<string, PresenceStatus | "offline"> = {};
      for (const uid of uids) {
        if (typeof uid === "string") {
          statuses[uid] = this.statusOf(uid);
        }
      }
      return Response.json({ statuses });
    }

    return new Response("not found", { status: 404 });
  }

  private acceptSocket(uid: string): Response {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    // One live socket per player: a fresh connection replaces the old one
    // (e.g. app restart before the stale socket times out).
    for (const existing of this.socketsOf(uid)) {
      existing.close(4000, "replaced");
    }

    this.ctx.acceptWebSocket(server, [uid]);
    server.serializeAttachment({ uid, status: "online" } satisfies Attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE_BYTES) {
      return;
    }
    let parsed: {
      t?: unknown;
      s?: unknown;
      to?: unknown;
      accept?: unknown;
      roomCode?: unknown;
    };
    try {
      parsed = JSON.parse(message) as typeof parsed;
    } catch {
      return;
    }
    const me = this.attachmentOf(ws);
    if (me === null) {
      return;
    }

    switch (parsed.t) {
      case "status": {
        if (
          parsed.s === "online" ||
          parsed.s === "solo" ||
          parsed.s === "versus"
        ) {
          ws.serializeAttachment({
            uid: me.uid,
            status: parsed.s,
          } satisfies Attachment);
        }
        break;
      }
      case "invite": {
        if (typeof parsed.to !== "string") {
          return;
        }
        const delivered = this.sendTo(parsed.to, {
          t: "invite",
          from: me.uid,
        });
        if (!delivered) {
          this.send(ws, { t: "invite_failed", to: parsed.to });
        }
        break;
      }
      case "invite_response": {
        if (typeof parsed.to !== "string") {
          return;
        }
        if (parsed.accept === true && typeof parsed.roomCode === "string") {
          this.sendTo(parsed.to, {
            t: "invite_accepted",
            from: me.uid,
            roomCode: parsed.roomCode,
          });
        } else {
          this.sendTo(parsed.to, { t: "invite_declined", from: me.uid });
        }
        break;
      }
      default:
        break;
    }
  }

  private statusOf(uid: string): PresenceStatus | "offline" {
    const sockets = this.socketsOf(uid);
    if (sockets.length === 0) {
      return "offline";
    }
    return this.attachmentOf(sockets[0])?.status ?? "online";
  }

  private socketsOf(uid: string): WebSocket[] {
    return this.ctx
      .getWebSockets(uid)
      .filter((ws) => ws.readyState === WebSocket.READY_STATE_OPEN);
  }

  private attachmentOf(ws: WebSocket): Attachment | null {
    try {
      return ws.deserializeAttachment() as Attachment | null;
    } catch {
      return null;
    }
  }

  private sendTo(uid: string, message: Record<string, unknown>): boolean {
    const sockets = this.socketsOf(uid);
    if (sockets.length === 0) {
      return false;
    }
    for (const ws of sockets) {
      this.send(ws, message);
    }
    return true;
  }

  private send(ws: WebSocket, message: Record<string, unknown>) {
    try {
      ws.send(JSON.stringify(message));
    } catch {
      // Receiver already gone.
    }
  }
}
