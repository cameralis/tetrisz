import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { signTestToken } from "./auth_helper";

interface ReportResponse {
  status: "pending" | "rated" | "discarded";
  ratingDelta?: number;
  newRating?: number;
}

async function report(
  uid: string,
  roomCode: string,
  matchId: number,
  outcome: "won" | "lost",
): Promise<ReportResponse> {
  const response = await SELF.fetch("https://example.com/api/versus/result", {
    method: "POST",
    headers: { Authorization: `Bearer ${await signTestToken(uid)}` },
    body: JSON.stringify({ roomCode, matchId, outcome }),
  });
  expect(response.status).toBe(200);
  return (await response.json()) as ReportResponse;
}

async function profileRating(uid: string): Promise<number> {
  const response = await SELF.fetch("https://example.com/api/profile", {
    headers: { Authorization: `Bearer ${await signTestToken(uid)}` },
  });
  return ((await response.json()) as { rating: number }).rating;
}

describe("rated results + rankings", () => {
  it("requires auth to report", async () => {
    const response = await SELF.fetch(
      "https://example.com/api/versus/result",
      {
        method: "POST",
        body: JSON.stringify({ roomCode: "AAAAA", matchId: 1, outcome: "won" }),
      },
    );
    expect(response.status).toBe(401);
  });

  it("rates a match when both reports agree", async () => {
    const first = await report("elo-a", "RATED", 1, "won");
    expect(first.status).toBe("pending");

    const second = await report("elo-b", "RATED", 1, "lost");
    expect(second.status).toBe("rated");
    // Equal starting ratings: K/2 = 16 moves each way.
    expect(second.ratingDelta).toBe(-16);
    expect(second.newRating).toBe(1184);

    expect(await profileRating("elo-a")).toBe(1216);
    expect(await profileRating("elo-b")).toBe(1184);
  });

  it("discards disagreeing reports without touching ratings", async () => {
    await report("elo-c", "FIGHT", 1, "won");
    const second = await report("elo-d", "FIGHT", 1, "won");
    expect(second.status).toBe("discarded");
    expect(await profileRating("elo-c")).toBe(1200);
    expect(await profileRating("elo-d")).toBe(1200);
  });

  it("re-polling after the pair completes returns the rating delta", async () => {
    await report("elo-g", "POLLY", 1, "won");
    await report("elo-h", "POLLY", 1, "lost");

    const poll = await report("elo-g", "POLLY", 1, "won");
    expect(poll.status).toBe("rated");
    expect(poll.ratingDelta).toBe(16);
    expect(poll.newRating).toBe(1216);
  });

  it("ignores duplicate reports from the same player", async () => {
    const first = await report("elo-e", "DUPES", 1, "won");
    expect(first.status).toBe("pending");
    const again = await report("elo-e", "DUPES", 1, "won");
    expect(again.status).toBe("pending");
    // The real counterpart still completes the pair.
    const second = await report("elo-f", "DUPES", 1, "lost");
    expect(second.status).toBe("rated");
  });

  it("ranks rated players and reports your own rank", async () => {
    await report("rank-a", "RANKY", 1, "won");
    await report("rank-b", "RANKY", 1, "lost");

    const anonymous = await SELF.fetch("https://example.com/api/rankings");
    expect(anonymous.status).toBe(200);
    const board = (await anonymous.json()) as {
      entries: { rank: number; rating: number }[];
      you: null;
    };
    expect(board.entries.length).toBeGreaterThanOrEqual(2);
    expect(board.you).toBeNull();
    // Sorted descending by rating.
    const ratings = board.entries.map((entry) => entry.rating);
    expect([...ratings].sort((a, b) => b - a)).toEqual(ratings);

    const authed = await SELF.fetch("https://example.com/api/rankings", {
      headers: { Authorization: `Bearer ${await signTestToken("rank-b")}` },
    });
    const withYou = (await authed.json()) as {
      you: { rank: number; rating: number } | null;
    };
    expect(withYou.you).not.toBeNull();
    expect(withYou.you!.rating).toBe(1184);
  });

  it("leaves unrated players off the board", async () => {
    // profile exists but no rated games
    await SELF.fetch("https://example.com/api/profile", {
      headers: { Authorization: `Bearer ${await signTestToken("lurker")}` },
    });
    const response = await SELF.fetch("https://example.com/api/rankings", {
      headers: { Authorization: `Bearer ${await signTestToken("lurker")}` },
    });
    const board = (await response.json()) as { you: unknown };
    expect(board.you).toBeNull();
  });
});
