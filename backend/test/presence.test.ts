import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { signTestToken } from "./auth_helper";

interface Envelope {
  t: string;
  [key: string]: unknown;
}

class Probe {
  readonly messages: Envelope[] = [];
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
    ws.accept();
  }

  next(type: string, timeoutMs = 2000): Promise<Envelope> {
    const existing = this.messages.find((m) => m.t === type);
    if (existing !== undefined) {
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`timed out waiting for "${type}"`)),
        timeoutMs,
      );
      this.waiters.push({
        predicate: (m) => m.t === type,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  }
}

async function connect(uid: string): Promise<Probe> {
  const token = await signTestToken(uid);
  const response = await SELF.fetch(
    `https://example.com/api/presence/ws?token=${token}`,
    { headers: { Upgrade: "websocket" } },
  );
  expect(response.status).toBe(101);
  return new Probe(response.webSocket!);
}

async function befriend(a: string, b: string): Promise<void> {
  const profile = await SELF.fetch("https://example.com/api/profile", {
    headers: { Authorization: `Bearer ${await signTestToken(b)}` },
  });
  const { friendCode } = (await profile.json()) as { friendCode: string };
  const add = await SELF.fetch("https://example.com/api/friends", {
    method: "POST",
    headers: { Authorization: `Bearer ${await signTestToken(a)}` },
    body: JSON.stringify({ friendCode }),
  });
  expect(add.status).toBe(200);
}

async function queryPresence(
  asUid: string,
  uids: string[],
): Promise<Record<string, string>> {
  const response = await SELF.fetch(
    "https://example.com/api/presence/query",
    {
      method: "POST",
      headers: { Authorization: `Bearer ${await signTestToken(asUid)}` },
      body: JSON.stringify({ uids }),
    },
  );
  expect(response.status).toBe(200);
  return ((await response.json()) as { statuses: Record<string, string> })
    .statuses;
}

describe("presence", () => {
  it("rejects the socket without a valid token", async () => {
    const response = await SELF.fetch(
      "https://example.com/api/presence/ws?token=garbage",
      { headers: { Upgrade: "websocket" } },
    );
    expect(response.status).toBe(401);
  });

  it("shows friends' status and hides strangers", async () => {
    await befriend("pr-a", "pr-b");
    const socket = await connect("pr-b");
    socket.ws.send(JSON.stringify({ t: "status", s: "solo" }));
    // Give the DO a beat to apply the status.
    await new Promise((resolve) => setTimeout(resolve, 50));

    const statuses = await queryPresence("pr-a", ["pr-b", "pr-stranger"]);
    expect(statuses["pr-b"]).toBe("solo");
    // Strangers are filtered out entirely, not reported as offline.
    expect(statuses["pr-stranger"]).toBeUndefined();
  });

  it("reports offline friends", async () => {
    await befriend("pr-c", "pr-d");
    const statuses = await queryPresence("pr-c", ["pr-d"]);
    expect(statuses["pr-d"]).toBe("offline");
  });

  it("routes invites and responses between online players", async () => {
    const alice = await connect("pr-alice");
    const bob = await connect("pr-bob");

    alice.ws.send(JSON.stringify({ t: "invite", to: "pr-bob" }));
    const invite = await bob.next("invite");
    expect(invite.from).toBe("pr-alice");

    bob.ws.send(
      JSON.stringify({
        t: "invite_response",
        to: "pr-alice",
        accept: true,
        roomCode: "QQQQQ",
      }),
    );
    const accepted = await alice.next("invite_accepted");
    expect(accepted.roomCode).toBe("QQQQQ");
    expect(accepted.from).toBe("pr-bob");
  });

  it("tells the inviter when the target is offline", async () => {
    const carol = await connect("pr-carol");
    carol.ws.send(JSON.stringify({ t: "invite", to: "pr-nobody" }));
    const failed = await carol.next("invite_failed");
    expect(failed.to).toBe("pr-nobody");
  });

  it("routes declines", async () => {
    const dave = await connect("pr-dave");
    const erin = await connect("pr-erin");
    dave.ws.send(JSON.stringify({ t: "invite", to: "pr-erin" }));
    await erin.next("invite");
    erin.ws.send(
      JSON.stringify({ t: "invite_response", to: "pr-dave", accept: false }),
    );
    const declined = await dave.next("invite_declined");
    expect(declined.from).toBe("pr-erin");
  });
});
