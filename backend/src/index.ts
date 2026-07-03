import { RoomDO } from "./room";

export { RoomDO };

export interface Env {
  ROOM: DurableObjectNamespace;
}

// No 0/O or 1/I so codes survive being read aloud.
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 5;
const CREATE_ATTEMPTS = 3;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function generateCode(): string {
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  let code = "";
  for (const byte of bytes) {
    code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
  }
  return code;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (url.pathname === "/api/health") {
      return json({ ok: true, now: Date.now() });
    }

    if (url.pathname === "/api/rooms" && request.method === "POST") {
      for (let attempt = 0; attempt < CREATE_ATTEMPTS; attempt += 1) {
        const code = generateCode();
        const stub = env.ROOM.get(env.ROOM.idFromName(code));
        const response = await stub.fetch("https://room/create", {
          method: "POST",
        });
        if (response.ok) {
          return json({ code }, 201);
        }
      }
      return json({ error: "could_not_allocate_room" }, 503);
    }

    const wsMatch = url.pathname.match(/^\/api\/rooms\/([A-Za-z0-9]{4,8})\/ws$/);
    if (wsMatch !== null && request.method === "GET") {
      const code = wsMatch[1].toUpperCase();
      const stub = env.ROOM.get(env.ROOM.idFromName(code));
      return stub.fetch(new Request("https://room/ws", request));
    }

    return json({ error: "not_found" }, 404);
  },
};
