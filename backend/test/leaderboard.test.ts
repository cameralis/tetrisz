import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

interface Entry {
  name: string;
  score: number;
  lines: number;
  level: number;
}

async function submit(entry: Partial<Entry>): Promise<Response> {
  return SELF.fetch("https://example.com/api/leaderboard", {
    method: "POST",
    body: JSON.stringify(entry),
  });
}

async function list(): Promise<{ entries: Entry[]; total: number }> {
  const response = await SELF.fetch("https://example.com/api/leaderboard");
  expect(response.status).toBe(200);
  return (await response.json()) as { entries: Entry[]; total: number };
}

describe("leaderboard", () => {
  it("stores entries sorted by score and returns ranks", async () => {
    expect((await (await submit({ name: "Alice", score: 5000, lines: 20, level: 3 })).json() as { rank: number }).rank).toBe(1);
    expect((await (await submit({ name: "Bob", score: 9000, lines: 36, level: 4 })).json() as { rank: number }).rank).toBe(1);
    expect((await (await submit({ name: "Carol", score: 1000, lines: 4, level: 1 })).json() as { rank: number }).rank).toBe(3);

    const board = await list();
    expect(board.entries.map((e) => e.name)).toEqual([
      "Bob",
      "Alice",
      "Carol",
    ]);
  });

  it("keeps only the best score per name", async () => {
    await submit({ name: "Dana", score: 3000 });
    await submit({ name: "Dana", score: 1500 });
    await submit({ name: "Dana", score: 7000 });

    const board = await list();
    const danas = board.entries.filter((e) => e.name === "Dana");
    expect(danas).toHaveLength(1);
    expect(danas[0].score).toBe(7000);
  });

  it("rejects invalid submissions", async () => {
    expect((await submit({ name: "", score: 100 })).status).toBe(400);
    expect((await submit({ name: "X", score: -5 })).status).toBe(400);
    expect((await submit({ name: "X", score: 1e12 })).status).toBe(400);
    expect(
      (
        await SELF.fetch("https://example.com/api/leaderboard", {
          method: "POST",
          body: "not json",
        })
      ).status,
    ).toBe(400);
  });

  it("sanitizes names", async () => {
    await submit({
      name: "  Ev\u0000il\u200e   Name that is way too long ",
      score: 42,
    });
    const board = await list();
    const entry = board.entries.find((e) => e.score === 42);
    expect(entry).toBeDefined();
    expect(entry!.name.length).toBeLessThanOrEqual(16);
    expect(entry!.name).not.toMatch(/[\u0000-\u001f\u200e]/);
    expect(entry!.name).not.toMatch(/ {2}/);
  });
});
