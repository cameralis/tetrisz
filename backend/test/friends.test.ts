import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { signTestToken } from "./auth_helper";

interface FriendView {
  uid: string;
  displayName: string;
  friendCode: string;
}

async function friendCodeOf(uid: string): Promise<string> {
  const response = await SELF.fetch("https://example.com/api/profile", {
    headers: { Authorization: `Bearer ${await signTestToken(uid)}` },
  });
  return ((await response.json()) as { friendCode: string }).friendCode;
}

async function addFriend(uid: string, code: string): Promise<Response> {
  return SELF.fetch("https://example.com/api/friends", {
    method: "POST",
    headers: { Authorization: `Bearer ${await signTestToken(uid)}` },
    body: JSON.stringify({ friendCode: code }),
  });
}

async function listFriends(uid: string): Promise<FriendView[]> {
  const response = await SELF.fetch("https://example.com/api/friends", {
    headers: { Authorization: `Bearer ${await signTestToken(uid)}` },
  });
  expect(response.status).toBe(200);
  return ((await response.json()) as { friends: FriendView[] }).friends;
}

describe("friends", () => {
  it("requires auth", async () => {
    const response = await SELF.fetch("https://example.com/api/friends");
    expect(response.status).toBe(401);
  });

  it("adds a friend by code, mutually", async () => {
    const codeB = await friendCodeOf("fr-b");
    const added = await addFriend("fr-a", codeB);
    expect(added.status).toBe(200);

    const aFriends = await listFriends("fr-a");
    expect(aFriends.map((f) => f.uid)).toContain("fr-b");
    const bFriends = await listFriends("fr-b");
    expect(bFriends.map((f) => f.uid)).toContain("fr-a");
  });

  it("rejects unknown, own, and duplicate codes", async () => {
    const unknown = await addFriend("fr-c", "ZZZZZZ");
    expect(unknown.status).toBe(404);

    const own = await addFriend("fr-c", await friendCodeOf("fr-c"));
    expect(own.status).toBe(400);

    const codeD = await friendCodeOf("fr-d");
    expect((await addFriend("fr-c", codeD)).status).toBe(200);
    expect((await addFriend("fr-c", codeD)).status).toBe(409);
  });

  it("removes a friendship from both sides", async () => {
    const codeF = await friendCodeOf("fr-f");
    await addFriend("fr-e", codeF);

    const remove = await SELF.fetch("https://example.com/api/friends/remove", {
      method: "POST",
      headers: { Authorization: `Bearer ${await signTestToken("fr-e")}` },
      body: JSON.stringify({ uid: "fr-f" }),
    });
    expect(remove.status).toBe(200);

    expect((await listFriends("fr-e")).map((f) => f.uid)).not.toContain(
      "fr-f",
    );
    expect((await listFriends("fr-f")).map((f) => f.uid)).not.toContain(
      "fr-e",
    );
  });
});
