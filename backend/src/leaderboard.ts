import { DurableObject } from "cloudflare:workers";

export interface LeaderboardEntry {
  name: string;
  score: number;
  lines: number;
  level: number;
  ts: number;
}

const MAX_STORED_ENTRIES = 100;
const LIST_LIMIT = 50;
const MAX_NAME_LENGTH = 16;
const MAX_SCORE = 99_999_999;
const MAX_BODY_BYTES = 1024;

/**
 * Single global leaderboard ("global" instance). Keeps the best score per
 * player name, top-100, in one storage key — write volume for a friends-scale
 * game makes contention a non-issue. Honest-client model: scores are
 * self-reported by the app.
 */
export class LeaderboardDO extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/list") {
      const entries = await this.entries();
      return Response.json({
        entries: entries.slice(0, LIST_LIMIT),
        total: entries.length,
      });
    }

    if (url.pathname === "/submit" && request.method === "POST") {
      const body = await request.text();
      if (body.length > MAX_BODY_BYTES) {
        return Response.json({ error: "payload_too_large" }, { status: 413 });
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {
        return Response.json({ error: "invalid_json" }, { status: 400 });
      }
      const entry = this.validate(parsed);
      if (entry === null) {
        return Response.json({ error: "invalid_entry" }, { status: 400 });
      }
      const rank = await this.insert(entry);
      return Response.json({ rank });
    }

    return new Response("not found", { status: 404 });
  }

  private async entries(): Promise<LeaderboardEntry[]> {
    return (
      (await this.ctx.storage.get<LeaderboardEntry[]>("entries")) ?? []
    );
  }

  private validate(input: unknown): LeaderboardEntry | null {
    if (typeof input !== "object" || input === null) {
      return null;
    }
    const record = input as Record<string, unknown>;
    if (
      typeof record.name !== "string" ||
      typeof record.score !== "number" ||
      !Number.isInteger(record.score)
    ) {
      return null;
    }
    // Collapse whitespace and strip control characters from the name.
    const name = record.name
      .replace(/[\p{C}]/gu, "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, MAX_NAME_LENGTH)
      .trim();
    if (name.length === 0) {
      return null;
    }
    const score = record.score;
    if (score < 0 || score > MAX_SCORE) {
      return null;
    }
    const lines =
      typeof record.lines === "number" && Number.isInteger(record.lines)
        ? Math.max(0, Math.min(record.lines, 99_999))
        : 0;
    const level =
      typeof record.level === "number" && Number.isInteger(record.level)
        ? Math.max(1, Math.min(record.level, 999))
        : 1;
    return { name, score, lines, level, ts: Date.now() };
  }

  /** Inserts keeping the best score per name; returns the 1-based rank of
   * the player's best entry, or null if it fell outside the stored window. */
  private async insert(entry: LeaderboardEntry): Promise<number | null> {
    const entries = await this.entries();
    const existingIndex = entries.findIndex((e) => e.name === entry.name);
    if (existingIndex >= 0) {
      if (entries[existingIndex].score >= entry.score) {
        return existingIndex + 1;
      }
      entries.splice(existingIndex, 1);
    }
    let insertAt = entries.findIndex((e) => e.score < entry.score);
    if (insertAt === -1) {
      insertAt = entries.length;
    }
    entries.splice(insertAt, 0, entry);
    entries.length = Math.min(entries.length, MAX_STORED_ENTRIES);
    await this.ctx.storage.put("entries", entries);
    return insertAt < MAX_STORED_ENTRIES ? insertAt + 1 : null;
  }
}
