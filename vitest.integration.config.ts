import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // RLS checks hit a real Postgres instance through Supabase Auth --
    // slower than the pure unit tests, needs a longer timeout.
    testTimeout: 20_000,
    // Setup hooks create and sign in several users each. With every test
    // file running in parallel that is enough concurrent password hashing
    // to push GoTrue past the 10s default, which showed up as whole files
    // failing in beforeAll without a single failed assertion.
    hookTimeout: 30_000,
  },
});
