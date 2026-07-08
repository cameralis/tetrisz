import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

interface Envelope {
  t: string;
  [key: string]: unknown;
}

/** Collects incoming envelopes and lets tests await specific message types. */
class SocketProbe {
  readonly messages: Envelope[] = [];
  readonly closes: { code: number; reason: string }[] = [];
  private waiters: {
    predicate: (m: Envelope) => boolean;
    resolve: (m: Envelope) => void;
  }[] = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => {
      const parsed = JSON.parse(event.data as string) as Envelope;
      this.messages.push(parsed);
      this.waiters = this.waiters.filter((waiter) => {
        if (waiter.predicate(parsed)) {
          waiter.resolve(parsed);
          return false;
        }
        return true;
      });
    });
    ws.addEventListener("close", (event) => {
      this.closes.push({ code: event.code, reason: event.reason });
    });
    ws.accept();
  }

  next(type: string, timeoutMs = 2000): Promise<Envelope> {
    return this.nextWhere((m) => m.t === type, `"${type}"`, timeoutMs);
  }

  nextWhere(
    predicate: (m: Envelope) => boolean,
    label = "matching message",
    timeoutMs = 2000,
  ): Promise<Envelope> {
    const existing = this.messages.find(predicate);
    if (existing !== undefined) {
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`timed out waiting for ${label}`)),
        timeoutMs,
      );
      this.waiters.push({
        predicate,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  }

  async nextClose(timeoutMs = 2000): Promise<{ code: number; reason: string }> {
    const deadline = Date.now() + timeoutMs;
    while (this.closes.length === 0) {
      if (Date.now() > deadline) {
        throw new Error("timed out waiting for close");
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    return this.closes[0];
  }
}

async function createRoom(): Promise<string> {
  const response = await SELF.fetch("https://example.com/api/rooms", {
    method: "POST",
  });
  expect(response.status).toBe(201);
  const body = (await response.json()) as { code: string };
  expect(body.code).toMatch(/^[A-Z2-9]{5}$/);
  return body.code;
}

async function join(code: string, version?: number): Promise<SocketProbe> {
  const suffix = version === undefined ? "" : `?v=${version}`;
  const response = await SELF.fetch(
    `https://example.com/api/rooms/${code}/ws${suffix}`,
    { headers: { Upgrade: "websocket" } },
  );
  expect(response.status).toBe(101);
  const ws = response.webSocket;
  if (ws === null) {
    throw new Error("no websocket on upgrade response");
  }
  return new SocketProbe(ws);
}

const ready = (probe: SocketProbe) =>
  probe.ws.send(JSON.stringify({ t: "ready" }));

describe("rooms", () => {
  it("creates a room and pairs two players with the same seed", async () => {
    const code = await createRoom();

    const host = await join(code);
    const hostJoined = await host.next("joined");
    expect(hostJoined.role).toBe("host");
    expect(hostJoined.rejoin).toBe(false);

    const guest = await join(code);
    const guestJoined = await guest.next("joined");
    expect(guestJoined.role).toBe("guest");

    await host.next("peer_joined");
    const hostStart = await host.next("start");
    const guestStart = await guest.next("start");
    expect(hostStart.seed).toBe(guestStart.seed);
    expect(typeof hostStart.seed).toBe("number");
    expect(hostStart.matchId).toBe(1);
  });

  it("forwards signal and relay payloads verbatim to the peer only", async () => {
    const code = await createRoom();
    const host = await join(code);
    const guest = await join(code);
    await host.next("start");
    await guest.next("start");

    host.ws.send(JSON.stringify({ t: "signal", d: { sdp: "offer-blob" } }));
    const signal = await guest.next("signal");
    expect(signal.d).toEqual({ sdp: "offer-blob" });

    guest.ws.send(
      JSON.stringify({ t: "relay", d: { v: 1, kind: "attack", seq: 7 } }),
    );
    const relay = await host.next("relay");
    expect(relay.d).toEqual({ v: 1, kind: "attack", seq: 7 });
    // The sender must not receive its own message back.
    expect(host.messages.filter((m) => m.t === "signal")).toHaveLength(0);
  });

  it("answers ping without involving the peer", async () => {
    const code = await createRoom();
    const host = await join(code);
    host.ws.send(JSON.stringify({ t: "ping" }));
    await host.next("pong");
  });

  it("rejects a third join with the room-full close code", async () => {
    const code = await createRoom();
    await join(code);
    await join(code);
    const third = await join(code);
    const close = await third.nextClose();
    expect(close.code).toBe(4409);
  });

  it("rejects joining a room that was never created", async () => {
    const probe = await join("ZZZZZ");
    const close = await probe.nextClose();
    expect(close.code).toBe(4404);
  });

  it("notifies the survivor when a peer disconnects", async () => {
    const code = await createRoom();
    const host = await join(code);
    const guest = await join(code);
    await guest.next("start");

    guest.ws.close();
    await host.next("peer_left");
  });

  it("starts a new match with a fresh seed once both request a rematch", async () => {
    const code = await createRoom();
    const host = await join(code);
    const guest = await join(code);
    const first = await host.next("start");
    await guest.next("start");

    host.ws.send(JSON.stringify({ t: "rematch" }));
    await guest.next("rematch_requested");
    guest.ws.send(JSON.stringify({ t: "rematch" }));

    const isSecondStart = (m: Envelope) => m.t === "start" && m.matchId === 2;
    const hostSecond = await host.nextWhere(isSecondStart, "second start");
    const guestSecond = await guest.nextWhere(isSecondStart, "second start");
    expect(hostSecond.seed).toBe(guestSecond.seed);
    expect(hostSecond.seed).not.toBe(first.seed);
  });

  it("gates the start on both v2 players sending ready", async () => {
    const code = await createRoom();
    const host = await join(code, 2);
    const hostJoined = await host.next("joined");
    expect(hostJoined.peerPresent).toBe(false);
    expect(hostJoined.peerReady).toBe(false);

    const guest = await join(code, 2);
    const guestJoined = await guest.next("joined");
    expect(guestJoined.peerPresent).toBe(true);
    expect(guestJoined.peerReady).toBe(false);
    await host.next("peer_joined");

    ready(host);
    const peerReady = await guest.next("peer_ready");
    expect(peerReady.t).toBe("peer_ready");
    // One ready is not enough.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(host.messages.filter((m) => m.t === "start")).toHaveLength(0);

    ready(guest);
    await host.next("peer_ready");
    const hostStart = await host.next("start");
    const guestStart = await guest.next("start");
    expect(hostStart.seed).toBe(guestStart.seed);
    expect(hostStart.matchId).toBe(1);
  });

  it("resets ready when a player disconnects during the ready phase", async () => {
    const code = await createRoom();
    const host = await join(code, 2);
    const guest = await join(code, 2);
    await guest.next("joined");

    ready(host);
    await guest.next("peer_ready");
    host.ws.close();
    await guest.next("peer_left");

    const hostBack = await join(code, 2);
    const joined = await hostBack.next("joined");
    // The guest never readied; the returning host's own flag was reset too.
    expect(joined.peerReady).toBe(false);

    ready(guest);
    await hostBack.next("peer_ready");
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(hostBack.messages.filter((m) => m.t === "start")).toHaveLength(0);

    ready(hostBack);
    await hostBack.next("start");
    await guest.next("start");
  });

  it("auto-starts when a legacy client is in the pair", async () => {
    const code = await createRoom();
    const host = await join(code); // legacy, no ?v=
    const guest = await join(code, 2);
    await host.next("start");
    await guest.next("start");
  });

  it("runs the rematch flow after a ready-gated first match", async () => {
    const code = await createRoom();
    const host = await join(code, 2);
    const guest = await join(code, 2);
    await guest.next("joined");
    ready(host);
    ready(guest);
    await host.next("start");
    await guest.next("start");

    host.ws.send(JSON.stringify({ t: "rematch" }));
    await guest.next("rematch_requested");
    guest.ws.send(JSON.stringify({ t: "rematch" }));

    const isSecondStart = (m: Envelope) => m.t === "start" && m.matchId === 2;
    await host.nextWhere(isSecondStart, "second start");
    await guest.nextWhere(isSecondStart, "second start");
  });

  it("reports rejoin=true when reconnecting to a started match", async () => {
    const code = await createRoom();
    const host = await join(code);
    const guest = await join(code);
    await host.next("start");
    await guest.next("start");

    guest.ws.close();
    await host.next("peer_left");

    const rejoined = await join(code);
    const joined = await rejoined.next("joined");
    expect(joined.rejoin).toBe(true);
    expect(joined.role).toBe("guest");
    await host.next("peer_rejoined");
  });
});

describe("health", () => {
  it("responds with ok", async () => {
    const response = await SELF.fetch("https://example.com/api/health");
    expect(response.status).toBe(200);
    const body = (await response.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });
});
