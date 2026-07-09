// Firebase ID-token verification for authenticated routes.
//
// Tokens are RS256 JWTs minted by Firebase Auth. We verify the signature
// against Google's securetoken JWKS (cached in-memory per isolate) and check
// iss/aud/exp/sub against the configured project. Tests bypass the network
// by providing the public key directly via TEST_JWK.

export interface AuthEnv {
  FIREBASE_PROJECT_ID?: string;
  /** Test hook: JSON JWK used instead of fetching Google's JWKS. */
  TEST_JWK?: string;
}

export interface AuthedUser {
  uid: string;
}

const JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
const JWKS_TTL_MS = 60 * 60 * 1000;

interface CachedJwks {
  fetchedAt: number;
  keys: Map<string, JsonWebKey>;
}

let jwksCache: CachedJwks | null = null;

function base64UrlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJson(segment: string): Record<string, unknown> | null {
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment))) as
      Record<string, unknown>;
  } catch {
    return null;
  }
}

async function keyFor(kid: string | undefined, env: AuthEnv): Promise<JsonWebKey | null> {
  if (env.TEST_JWK !== undefined) {
    try {
      return JSON.parse(env.TEST_JWK) as JsonWebKey;
    } catch {
      return null;
    }
  }
  if (kid === undefined) {
    return null;
  }
  const now = Date.now();
  if (jwksCache === null || now - jwksCache.fetchedAt > JWKS_TTL_MS) {
    const response = await fetch(JWKS_URL);
    if (!response.ok) {
      return jwksCache?.keys.get(kid) ?? null;
    }
    const body = (await response.json()) as { keys: (JsonWebKey & { kid?: string })[] };
    const keys = new Map<string, JsonWebKey>();
    for (const key of body.keys) {
      if (key.kid !== undefined) {
        keys.set(key.kid, key);
      }
    }
    jwksCache = { fetchedAt: now, keys };
  }
  return jwksCache.keys.get(kid) ?? null;
}

/** Returns the verified user, or null when the token is missing/invalid. */
export async function verifyFirebaseToken(
  authorizationHeader: string | null,
  env: AuthEnv,
): Promise<AuthedUser | null> {
  const projectId = env.FIREBASE_PROJECT_ID;
  if (projectId === undefined || projectId === "") {
    return null;
  }
  if (authorizationHeader === null || !authorizationHeader.startsWith("Bearer ")) {
    return null;
  }
  const token = authorizationHeader.slice("Bearer ".length).trim();
  const segments = token.split(".");
  if (segments.length !== 3) {
    return null;
  }

  const header = decodeJson(segments[0]);
  const payload = decodeJson(segments[1]);
  if (header === null || payload === null || header.alg !== "RS256") {
    return null;
  }

  const jwk = await keyFor(
    typeof header.kid === "string" ? header.kid : undefined,
    env,
  );
  if (jwk === null) {
    return null;
  }

  let valid = false;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      base64UrlDecode(segments[2]),
      new TextEncoder().encode(`${segments[0]}.${segments[1]}`),
    );
  } catch {
    return null;
  }
  if (!valid) {
    return null;
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const exp = typeof payload.exp === "number" ? payload.exp : 0;
  const iss = typeof payload.iss === "string" ? payload.iss : "";
  const aud = typeof payload.aud === "string" ? payload.aud : "";
  const sub = typeof payload.sub === "string" ? payload.sub : "";
  if (
    exp <= nowSeconds ||
    iss !== `https://securetoken.google.com/${projectId}` ||
    aud !== projectId ||
    sub === ""
  ) {
    return null;
  }
  return { uid: sub };
}
