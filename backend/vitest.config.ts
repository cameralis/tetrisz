import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

import { TEST_PROJECT_ID, TEST_PUBLIC_JWK } from "./test/auth_helper";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          // Auth is disabled in the checked-in wrangler.toml (empty project
          // id); tests enable it with the fixed test keypair.
          FIREBASE_PROJECT_ID: TEST_PROJECT_ID,
          TEST_JWK: JSON.stringify(TEST_PUBLIC_JWK),
        },
      },
    }),
  ],
});
