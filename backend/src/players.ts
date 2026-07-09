import { DurableObject } from "cloudflare:workers";

// No 0/O or 1/I so friend codes survive being read aloud.
const FRIEND_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const FRIEND_CODE_LENGTH = 6;
const MAX_NAME_LENGTH = 16;
export const STARTING_RATING = 1200;

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
