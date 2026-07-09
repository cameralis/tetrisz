// Fixed RSA keypair for auth tests: the PUBLIC half is injected into the
// worker as TEST_JWK (see vitest.config.ts); tests sign tokens with the
// PRIVATE half. Never used outside tests.

export const TEST_PROJECT_ID = "tetrisz-test";

export const TEST_PUBLIC_JWK = {
  key_ops: ["verify"],
  ext: true,
  kty: "RSA",
  n: "yiIpgIYzX0eUZOXMNkX9UjjmcO4UnCYiVNSWth_9lPUsH-Rb7A39X8vNvO_zHmzUbILbfxksGJJAj9AF4NDV-IQWQWUE90m7sUEC4x9LRnz4FXx8d6NKLyBgOE4LeblDJRxEWyK61qsjWIjqewUtbbZeMKSNd_SmDFNMGkBi8Lpwx2Oa4r8F-HdXRUl423QoA7C__-E0eHO8DqhWX01ieOBBb-Nd62zsJ-2nQ9EVd-Fbkc0N_KUPFgxoLxlokkcK-7aq2a-JDcSgHx3jdG02Vh1ZI7Bx1GmvIZLUEwIPKpWH2VvvMO-mpQiPg89Ga3UtZSGxxOpvzNuTcPmFdCUJMw",
  e: "AQAB",
  alg: "RS256",
};

const TEST_PRIVATE_JWK = {
  key_ops: ["sign"],
  ext: true,
  kty: "RSA",
  n: TEST_PUBLIC_JWK.n,
  e: "AQAB",
  d: "AuQ5NsL0siy6dTUKVk5rAMWamkv1lIRBIniGDWXowTw-nNgt7nMGyFuIfmbqUemZolG-5RMNm-5fqQ7_PoeOQAdXsCjLSORPoIn_ChO1BnWcMOZ-e1GlKoZqifOn215olPvSCIG3LYH2N_qBbDAXRcYBk-2OroQb6fo5EPkR0UK6-gEnI9GwEhKN9DoTwOQoKgR1Lav0uAO-DUweOD-d-9plT4YXd0QjpTA5UfLsvq-ST1eK4pdK1b3q4bM73Mfp9Rg7PdiXLLTEveEXa4srOqL1q5poMTC0LuomqhStH-vV_YURRqFY4g0kycO_m7nINhod9_MZoipRQ6vbG5YoVQ",
  p: "9iE8b4IDZn_h1KXGVJYqOiqVd2ViBwv2SRAzET02AeUDxPDtiw_PoYhQxtVwoFoIZQtaqhor9V_NIZo67Pc_24TgsUiKFQlyYcSXPiFSrotN1clZbiehbEg5Up8PvsFS_Wycd3Gx7ZqkvvQUKECviRpgXHHNx9B7OZ5eB2giqIc",
  q: "0j1Ckr3CV9tDckx90n7uKeAJWCIJpvJNpPRO5kdo0wAqQ_48agoBzeEMSRrjVwyO05ilZEH_eC8CnwXjG55drrX_zH1lEnN5lFRKfUiQ94eVrPp47jZvr39IatyTGCIAErl2wFQqVNpSp8NUnbI-N8eX8cYN404sWdNkzYZoQPU",
  dp: "8yAXk8po03olOKncRLfk1Ho2FK-n6nANg1SmLTQ6whpX49VdwE0I-3Ys3Iv_6dWljzJtB7Q8kfBlL_kqleMSSCR004plI6ymOR85itzd0J64byKq3V32XYDmZs_KfNJ4yO7djDtZ1-w3Kozt0Gk9PAA7CXY9IFC3OE5QcZ6TBcc",
  dq: "rhuxgFjKE3wwFP4nzST1E5TH6Eb3-1v61TrGBIrq0qL2Xay0V5TF_bv8Mqaj0zlBJxbpEWheqyczYoK7m-nA56ktmCnYhDlBXIeZ0LtB4txUJhagA5btU0dzr5vP7VJrARa6s3iAPhk4DlsDPj2YrRUMTluYsL_SluksN9Cxkek",
  qi: "M8VQ-sOCcY7_AJd6vAMDLh3uRZoKcP7e9POPlmobBC0tbLMkRSHaCCPLPGupa-e4oyekETq99qk3kKGeWBNZ7mlQzwWDMXTTJ12bngvO-o2-l5N1s5tW8DiIsWLfZstHoSoDsByjmmc47iYNbCRbqtcyNP6ITogAfApT9mTJ2TE",
  alg: "RS256",
};

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function encodeSegment(value: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

/** Signs a Firebase-shaped ID token for [uid] with the test key. */
export async function signTestToken(
  uid: string,
  {
    projectId = TEST_PROJECT_ID,
    expiresInSeconds = 3600,
  }: { projectId?: string; expiresInSeconds?: number } = {},
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT", kid: "test-key" };
  const payload = {
    iss: `https://securetoken.google.com/${projectId}`,
    aud: projectId,
    sub: uid,
    iat: now,
    exp: now + expiresInSeconds,
  };
  const signingInput = `${encodeSegment(header)}.${encodeSegment(payload)}`;
  const key = await crypto.subtle.importKey(
    "jwk",
    TEST_PRIVATE_JWK,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}
