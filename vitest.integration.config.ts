import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // RLS checks hit a real Postgres instance through Supabase Auth --
    // slower than the pure unit tests, needs a longer timeout.
    testTimeout: 20_000,
  },
});
