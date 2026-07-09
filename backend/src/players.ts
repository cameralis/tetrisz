import { DurableObject } from "cloudflare:workers";

// No 0/O or 1/I so friend codes survive being read aloud.
const FRIEND_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const FRIEND_CODE_LENGTH = 6;
const MAX_NAME_LENGTH = 16;
export const STARTING_RATING = 1200;
export const ELO_K = 32;
// A lone result report with no matching counterpart is discarded after this.
const RESULT_PAIR_TTL_MS = 2 * 60 * 1000;
const RANKING_LIMIT = 100;

export function eloDelta(winner: number, loser: number): number {
  const expected = 1 / (1 + 10 ** ((loser - winner) / 400));
  return Math.round(ELO_K * (1 - expected));
}

interface PendingResult {
  uid: string;
  outcome: "won" | "lost";
  at: number;
}

export interface PlayerProfile {
  uid: string;
  displayName: string;
  friendCode: string;
  rating: number;
  ratedGames: number;
  createdAt: number;
}

function sanitizeName(raw: unknown): string {
  if (typeof raw !== "string") {
    return "";
  }
  return raw.replace(/[^\p{L}\p{N} _.-]/gu, "").trim().slice(0, MAX_NAME_LENGTH);
}

/**
 * Single global registry of player profiles, keyed by Firebase uid. Also owns
 * the friend-code index (code -> uid). Small player counts make one DO fine;
 * shard later if it ever matters.
 */
export class PlayersDO extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/get-or-create" && request.method === "POST") {
      const { uid } = (await request.json()) as { uid?: string };
      if (typeof uid !== "string" || uid === "") {
        return new Response("bad uid", { status: 400 });
      }
      const profile = await this.getOrCreate(uid);
      return Response.json(profile);
    }

    if (url.pathname === "/report-result" && request.method === "POST") {
      const { uid, roomCode, matchId, outcome } = (await request.json()) as {
        uid?: string;
        roomCode?: string;
        matchId?: number;
        outcome?: string;
      };
      if (
        typeof uid !== "string" ||
        uid === "" ||
        typeof roomCode !== "string" ||
        !/^[A-Z2-9]{4,8}$/.test(roomCode) ||
        typeof matchId !== "number" ||
        !Number.isInteger(matchId) ||
        (outcome !== "won" && outcome !== "lost")
      ) {
        return new Response("bad report", { status: 400 });
      }
      return Response.json(
        await this.reportResult(uid, roomCode, matchId, outcome),
      );
    }

    if (url.pathname === "/rankings" && request.method === "POST") {
      const { uid } = (await request.json()) as { uid?: string };
      return Response.json(await this.rankings(uid));
    }

    if (url.pathname === "/friends/add" && request.method === "POST") {
      const { uid, friendCode } = (await request.json()) as {
        uid?: string;
        friendCode?: string;
      };
      if (
        typeof uid !== "string" ||
        uid === "" ||
        typeof friendCode !== "string" ||
        !/^[A-Z2-9]{6}$/.test(friendCode)
      ) {
        return new Response("bad request", { status: 400 });
      }
      const otherUid = await this.ctx.storage.get<string>(`fc:${friendCode}`);
      if (otherUid === undefined) {
        return Response.json({ error: "unknown_code" }, { status: 404 });
      }
      if (otherUid === uid) {
        return Response.json({ error: "own_code" }, { status: 400 });
      }
      await this.getOrCreate(uid);
      const mine = await this.friendSet(uid);
      if (mine.includes(otherUid)) {
        return Response.json({ error: "already_friends" }, { status: 409 });
      }
      const theirs = await this.friendSet(otherUid);
      mine.push(otherUid);
      theirs.push(uid);
      await this.ctx.storage.put(`fr:${uid}`, mine);
      await this.ctx.storage.put(`fr:${otherUid}`, theirs);
      const profile = await this.getOrCreate(otherUid);
      return Response.json(this.friendView(profile));
    }

    if (url.pathname === "/friends/list" && request.method === "POST") {
      const { uid } = (await request.json()) as { uid?: string };
      if (typeof uid !== "string" || uid === "") {
        return new Response("bad uid", { status: 400 });
      }
      const friends = await this.friendSet(uid);
      const views = [];
      for (const friendUid of friends) {
        views.push(this.friendView(await this.getOrCreate(friendUid)));
      }
      return Response.json({ friends: views });
    }

    if (url.pathname === "/friends/remove" && request.method === "POST") {
      const { uid, otherUid } = (await request.json()) as {
        uid?: string;
        otherUid?: string;
      };
      if (
        typeof uid !== "string" ||
        uid === "" ||
        typeof otherUid !== "string" ||
        otherUid === ""
      ) {
        return new Response("bad request", { status: 400 });
      }
      const mine = (await this.friendSet(uid)).filter((f) => f !== otherUid);
      const theirs = (await this.friendSet(otherUid)).filter((f) => f !== uid);
      await this.ctx.storage.put(`fr:${uid}`, mine);
      await this.ctx.storage.put(`fr:${otherUid}`, theirs);
      return Response.json({ ok: true });
    }

    if (url.pathname === "/update-name" && request.method === "POST") {
      const { uid, displayName } = (await request.json()) as {
        uid?: string;
        displayName?: unknown;
      };
      if (typeof uid !== "string" || uid === "") {
        return new Response("bad uid", { status: 400 });
      }
      const name = sanitizeName(displayName);
      if (name === "") {
        return new Response("bad name", { status: 400 });
      }
      const profile = await this.getOrCreate(uid);
      profile.displayName = name;
      await this.ctx.storage.put(`p:${uid}`, profile);
      return Response.json(profile);
    }

    return new Response("not found", { status: 404 });
  }

  private async getOrCreate(uid: string): Promise<PlayerProfile> {
    const existing = await this.ctx.storage.get<PlayerProfile>(`p:${uid}`);
    if (existing !== undefined) {
      return existing;
    }
    const profile: PlayerProfile = {
      uid,
      displayName: "",
      friendCode: await this.allocateFriendCode(uid),
      rating: STARTING_RATING,
      ratedGames: 0,
      createdAt: Date.now(),
    };
    await this.ctx.storage.put(`p:${uid}`, profile);
    return profile;
  }

  /**
   * Honest-client rated results: each player reports their own outcome for
   * (room, match). Ratings move only when both reports exist, come from two
   * different players, and are complementary (one won, one lost). Anything
   * else — disagreement, duplicates, a report that never gets a counterpart
   * within the TTL — leaves ratings untouched. The RoomDO stays out of it
   * entirely (opaque-relay invariant).
   */
  private async reportResult(
    uid: string,
    roomCode: string,
    matchId: number,
    outcome: "won" | "lost",
  ): Promise<{
    status: "pending" | "rated" | "discarded";
    ratingDelta?: number;
    newRating?: number;
  }> {
    const key = `mr:${roomCode}:${matchId}`;
    const doneKey = `mrdone:${roomCode}:${matchId}`;
    const done = await this.ctx.storage.get<{
      winnerUid: string;
      loserUid: string;
      delta: number;
    }>(doneKey);
    if (done !== undefined) {
      // Pair already rated; a re-poll from either player gets their delta.
      if (uid === done.winnerUid || uid === done.loserUid) {
        const me = await this.getOrCreate(uid);
        return {
          status: "rated",
          ratingDelta: uid === done.winnerUid ? done.delta : -done.delta,
          newRating: me.rating,
        };
      }
      return { status: "discarded" };
    }
    const pending = await this.ctx.storage.get<PendingResult>(key);
    const now = Date.now();

    if (pending === undefined || now - pending.at > RESULT_PAIR_TTL_MS) {
      await this.ctx.storage.put(key, {
        uid,
        outcome,
        at: now,
      } satisfies PendingResult);
      return { status: "pending" };
    }
    if (pending.uid === uid) {
      // Duplicate report from the same player; keep waiting for the peer.
      return { status: "pending" };
    }

    await this.ctx.storage.delete(key);
    if (pending.outcome === outcome) {
      return { status: "discarded" }; // Both claim the same result.
    }

    const winnerUid = outcome === "won" ? uid : pending.uid;
    const loserUid = outcome === "won" ? pending.uid : uid;
    const winner = await this.getOrCreate(winnerUid);
    const loser = await this.getOrCreate(loserUid);
    const delta = eloDelta(winner.rating, loser.rating);
    winner.rating += delta;
    winner.ratedGames += 1;
    loser.rating = Math.max(0, loser.rating - delta);
    loser.ratedGames += 1;
    await this.ctx.storage.put(`p:${winnerUid}`, winner);
    await this.ctx.storage.put(`p:${loserUid}`, loser);
    await this.ctx.storage.put(doneKey, { winnerUid, loserUid, delta });

    const mine = uid === winnerUid ? delta : -delta;
    const myRating = uid === winnerUid ? winner.rating : loser.rating;
    return { status: "rated", ratingDelta: mine, newRating: myRating };
  }

  private async rankings(uid: string | undefined): Promise<{
    entries: {
      rank: number;
      displayName: string;
      rating: number;
      ratedGames: number;
    }[];
    you: { rank: number; rating: number; ratedGames: number } | null;
  }> {
    const stored = await this.ctx.storage.list<PlayerProfile>({
      prefix: "p:",
    });
    const ranked = [...stored.values()]
      .filter((profile) => profile.ratedGames > 0)
      .sort((a, b) => b.rating - a.rating);
    const entries = ranked.slice(0, RANKING_LIMIT).map((profile, index) => ({
      rank: index + 1,
      displayName: profile.displayName === "" ? "???" : profile.displayName,
      rating: profile.rating,
      ratedGames: profile.ratedGames,
    }));
    let you: { rank: number; rating: number; ratedGames: number } | null =
      null;
    if (uid !== undefined) {
      const index = ranked.findIndex((profile) => profile.uid === uid);
      if (index >= 0) {
        you = {
          rank: index + 1,
          rating: ranked[index].rating,
          ratedGames: ranked[index].ratedGames,
        };
      }
    }
    return { entries, you };
  }

  private async friendSet(uid: string): Promise<string[]> {
    return (await this.ctx.storage.get<string[]>(`fr:${uid}`)) ?? [];
  }

  private friendView(profile: PlayerProfile): {
    uid: string;
    displayName: string;
    friendCode: string;
    rating: number;
    ratedGames: number;
  } {
    return {
      uid: profile.uid,
      displayName: profile.displayName === "" ? "???" : profile.displayName,
      friendCode: profile.friendCode,
      rating: profile.rating,
      ratedGames: profile.ratedGames,
    };
  }

  private async allocateFriendCode(uid: string): Promise<string> {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const bytes = new Uint8Array(FRIEND_CODE_LENGTH);
      crypto.getRandomValues(bytes);
      let code = "";
      for (const byte of bytes) {
        code += FRIEND_CODE_ALPHABET[byte % FRIEND_CODE_ALPHABET.length];
      }
      const taken = await this.ctx.storage.get<string>(`fc:${code}`);
      if (taken === undefined) {
        await this.ctx.storage.put(`fc:${code}`, uid);
        return code;
      }
    }
    throw new Error("could not allocate a friend code");
  }
}
