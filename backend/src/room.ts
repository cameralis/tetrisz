import { DurableObject } from "cloudflare:workers";

import {
  CLOSE_ROOM_FULL,
  CLOSE_ROOM_NOT_FOUND,
  type Role,
  type ServerMessage,
} from "./protocol";

interface Attachment {
  role: Role;
  /** Client protocol version from the ws URL (`?v=`); 1 when absent. */
  v: number;
}

// A room stays alive this long past its last join/start/rematch while sockets
// are connected; the alarm re-arms itself for active rooms so relayed game
// traffic never needs to touch storage.
const ROOM_TTL_MS = 30 * 60 * 1000;
// An empty room (both players gone) is torn down after this long.
const EMPTY_ROOM_TTL_MS = 60 * 1000;
const MAX_MESSAGE_BYTES = 16 * 1024;

/**
 * One Durable Object per room code. It pairs exactly two WebSockets, hands
 * both the same RNG seed, forwards WebRTC signaling and (as fallback
 * transport) opaque relayed game messages between them, and expires itself
 * via alarms. Uses the WebSocket Hibernation API throughout.
 */
export class RoomDO extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env as never);
    ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'),
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/create" && request.method === "POST") {
      const createdAt = await this.ctx.storage.get<number>("createdAt");
      if (createdAt !== undefined) {
        return new Response("room already exists", { status: 409 });
      }
      await this.ctx.storage.put({ createdAt: Date.now(), matchIndex: 0 });
      await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
      return new Response(null, { status: 201 });
    }

    if (url.pathname === "/ws") {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const version = Number.parseInt(url.searchParams.get("v") ?? "1", 10);
      return this.acceptSocket(Number.isFinite(version) ? version : 1);
    }

    return new Response("not found", { status: 404 });
  }

  private async acceptSocket(version: number): Promise<Response> {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    const createdAt = await this.ctx.storage.get<number>("createdAt");
    if (createdAt === undefined) {
      // Accept then close so browser clients (which cannot read HTTP upgrade
      // failure codes) still get a meaningful close code.
      this.ctx.acceptWebSocket(server);
      server.close(CLOSE_ROOM_NOT_FOUND, "room not found");
      return new Response(null, { status: 101, webSocket: client });
    }

    const live = this.liveSockets();
    if (live.length >= 2) {
      this.ctx.acceptWebSocket(server);
      server.close(CLOSE_ROOM_FULL, "room full");
      return new Response(null, { status: 101, webSocket: client });
    }

    const takenRoles = new Set(live.map((ws) => this.roleOf(ws)));
    const role: Role = takenRoles.has("host") ? "guest" : "host";
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, v: version } satisfies Attachment);

    const started = (await this.ctx.storage.get<boolean>("started")) ?? false;
    const peer = this.peerOf(server);
    const peerRole: Role = role === "host" ? "guest" : "host";
    const peerReady =
      peer !== undefined &&
      ((await this.ctx.storage.get<boolean>(`ready:${peerRole}`)) ?? false);
    this.send(server, {
      t: "joined",
      role,
      rejoin: started,
      peerPresent: peer !== undefined,
      peerReady,
    });
    if (peer !== undefined) {
      this.send(peer, { t: started ? "peer_rejoined" : "peer_joined" });
    }

    if (!started && this.liveSockets().length === 2) {
      // Ready-up gate (protocol v2). A legacy client never sends `ready`, so
      // a pair including one starts immediately like it always did.
      if (this.allSocketsAtLeast(2)) {
        await this.maybeStartWhenBothReady();
      } else {
        await this.startMatch();
      }
    } else {
      await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE_BYTES) {
      return;
    }
    let parsed: { t?: unknown };
    try {
      parsed = JSON.parse(message) as { t?: unknown };
    } catch {
      return;
    }

    switch (parsed.t) {
      case "signal":
      case "relay": {
        // Forward the original string verbatim; the backend never interprets
        // signaling or game payloads.
        this.peerOf(ws)?.send(message);
        break;
      }
      case "ready": {
        await this.handleReady(ws);
        break;
      }
      case "rematch": {
        await this.handleRematch(ws);
        break;
      }
      default:
        break;
    }
  }

  async webSocketClose(ws: WebSocket) {
    const role = this.roleOf(ws);
    if (role === undefined) {
      return; // A socket we rejected at accept time.
    }
    // Leaving the ready phase forfeits the ready state; a rejoiner must
    // ready up again.
    const started = (await this.ctx.storage.get<boolean>("started")) ?? false;
    if (!started) {
      await this.ctx.storage.put(`ready:${role}`, false);
    }
    const peer = this.peerOf(ws);
    if (peer !== undefined) {
      this.send(peer, { t: "peer_left" });
      await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
    } else {
      await this.ctx.storage.setAlarm(Date.now() + EMPTY_ROOM_TTL_MS);
    }
  }

  async alarm() {
    if (this.liveSockets().length > 0) {
      await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
      return;
    }
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
  }

  private async handleReady(ws: WebSocket) {
    const role = this.roleOf(ws);
    if (role === undefined) {
      return;
    }
    const started = (await this.ctx.storage.get<boolean>("started")) ?? false;
    if (started) {
      return; // Ready only gates the first match; rematches use `rematch`.
    }
    await this.ctx.storage.put(`ready:${role}`, true);
    const peer = this.peerOf(ws);
    if (peer !== undefined) {
      this.send(peer, { t: "peer_ready" });
    }
    await this.maybeStartWhenBothReady();
  }

  private async maybeStartWhenBothReady() {
    const hostReady =
      (await this.ctx.storage.get<boolean>("ready:host")) ?? false;
    const guestReady =
      (await this.ctx.storage.get<boolean>("ready:guest")) ?? false;
    if (hostReady && guestReady && this.liveSockets().length === 2) {
      await this.startMatch();
    } else {
      await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
    }
  }

  private allSocketsAtLeast(version: number): boolean {
    return this.liveSockets().every((ws) => this.versionOf(ws) >= version);
  }

  private async handleRematch(ws: WebSocket) {
    const role = this.roleOf(ws);
    if (role === undefined) {
      return;
    }
    await this.ctx.storage.put(`rematch:${role}`, true);
    const other: Role = role === "host" ? "guest" : "host";
    const otherWants =
      (await this.ctx.storage.get<boolean>(`rematch:${other}`)) ?? false;
    if (otherWants && this.liveSockets().length === 2) {
      await this.startMatch();
    } else {
      const peer = this.peerOf(ws);
      if (peer !== undefined) {
        this.send(peer, { t: "rematch_requested" });
      }
    }
  }

  private async startMatch() {
    const matchIndex =
      ((await this.ctx.storage.get<number>("matchIndex")) ?? 0) + 1;
    const seed = crypto.getRandomValues(new Uint32Array(1))[0];
    await this.ctx.storage.put({
      started: true,
      matchIndex,
      "ready:host": false,
      "ready:guest": false,
      "rematch:host": false,
      "rematch:guest": false,
    });
    for (const ws of this.liveSockets()) {
      this.send(ws, { t: "start", seed, matchId: matchIndex });
    }
    await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
  }

  /** Sockets that joined successfully (rejected ones carry no attachment). */
  private liveSockets(): WebSocket[] {
    return this.ctx
      .getWebSockets()
      .filter(
        (ws) =>
          ws.readyState === WebSocket.READY_STATE_OPEN &&
          this.roleOf(ws) !== undefined,
      );
  }

  private peerOf(ws: WebSocket): WebSocket | undefined {
    return this.liveSockets().find((other) => other !== ws);
  }

  private roleOf(ws: WebSocket): Role | undefined {
    try {
      return (ws.deserializeAttachment() as Attachment | null)?.role;
    } catch {
      return undefined;
    }
  }

  private versionOf(ws: WebSocket): number {
    try {
      return (ws.deserializeAttachment() as Attachment | null)?.v ?? 1;
    } catch {
      return 1;
    }
  }

  private send(ws: WebSocket, message: ServerMessage) {
    try {
      ws.send(JSON.stringify(message));
    } catch {
      // Peer already gone; close/alarm handling cleans up.
    }
  }
}
