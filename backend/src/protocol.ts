// Server envelope — everything the room WebSocket speaks. Game messages ride
// inside `relay.d` and are intentionally opaque to the backend so the relay
// fallback never needs to learn the game protocol.

export type Role = "host" | "guest";

export type ServerMessage =
  | { t: "joined"; role: Role; rejoin: boolean }
  | { t: "peer_joined" }
  | { t: "peer_rejoined" }
  | { t: "peer_left" }
  | { t: "start"; seed: number; matchId: number }
  | { t: "rematch_requested" }
  | { t: "signal"; d: unknown }
  | { t: "relay"; d: unknown }
  | { t: "pong" };

export type ClientMessage =
  | { t: "signal"; d: unknown }
  | { t: "relay"; d: unknown }
  | { t: "rematch" }
  | { t: "ping" };

// WebSocket close codes used when a join is rejected.
export const CLOSE_ROOM_NOT_FOUND = 4404;
export const CLOSE_ROOM_FULL = 4409;
