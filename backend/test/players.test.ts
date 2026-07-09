import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { signTestToken } from "./auth_helper";

interface Profile {
  uid: string;
  displayName: string;
  friendCode: string;
  rating: number;
  ratedGames: number;
}

async function getProfile(token: string): Promise<Response> {
  return SELF.fetch("https://example.com/api/profile", {
    headers: { Authorization: `Bearer ${token}` },
  });
}

describe("profile", () => {
  it("rejects requests without a token", async () => {
    const response = await SELF.fetch("https://example.com/api/profile");
    expect(response.status).toBe(401);
  });

  it("rejects expired and wrong-audience tokens", async () => {
    const expired = await signTestToken("user-a", { expiresInSeconds: -10 });
    expect((await getProfile(expired)).status).toBe(401);

    const wrongProject = await signTestToken("user-a", {
      projectId: "someone-elses-app",
    });
    expect((await getProfile(wrongProject)).status).toBe(401);
  });

  it("rejects tampered tokens", async () => {
    const token = await signTestToken("user-a");
    const [header, payload] = token.split(".");
    const forgedPayload = btoa(
      JSON.stringify({
        iss: "https://securetoken.google.com/tetrisz-test",
        aud: "tetrisz-test",
        sub: "user-b",
        exp: Math.floor(Date.now() / 1000) + 3600,
      }),
    )
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    const forged = `${header}.${forgedPayload}.${token.split(".")[2]}`;
    expect((await getProfile(forged)).status).toBe(401);
  });

  it("creates a profile with a friend code and starting rating", async () => {
    const token = await signTestToken("user-fresh");
    const response = await getProfile(token);
    expect(response.status).toBe(200);
    const profile = (await response.json()) as Profile;
    expect(profile.uid).toBe("user-fresh");
    expect(profile.friendCode).toMatch(/^[A-Z2-9]{6}$/);
    expect(profile.rating).toBe(1200);
    expect(profile.ratedGames).toBe(0);

    // Idempotent: same uid keeps the same friend code.
    const again = (await (await getProfile(token)).json()) as Profile;
    expect(again.friendCode).toBe(profile.friendCode);
  });

  it("updates the display name with sanitization", async () => {
    const token = await signTestToken("user-name");
    await getProfile(token);

    const update = await SELF.fetch("https://example.com/api/profile", {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
      body: JSON.stringify({ displayName: "  Szabi<script> " }),
    });
    expect(update.status).toBe(200);
    const profile = (await update.json()) as Profile;
    expect(profile.displayName).toBe("Szabiscript");

    const bad = await SELF.fetch("https://example.com/api/profile", {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
      body: JSON.stringify({ displayName: "<<<>>>" }),
    });
    expect(bad.status).toBe(400);
  });

  it("keeps users separate", async () => {
    const a = (await (
      await getProfile(await signTestToken("user-a2"))
    ).json()) as Profile;
    const b = (await (
      await getProfile(await signTestToken("user-b2"))
    ).json()) as Profile;
    expect(a.friendCode).not.toBe(b.friendCode);
    expect(a.uid).not.toBe(b.uid);
  });
});
