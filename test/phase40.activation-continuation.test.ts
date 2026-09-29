// ADR-0040: the nonce that lets a customer activation (ADR-0026) survive a
// browser-context switch during login/signup/OAuth. Covers the four things
// the ADR actually depends on: a valid nonce redeems exactly once, an
// expired nonce fails, a nonce that never existed fails, and redemption
// hands back the real token so /auth/callback can replant the cookie.

import { createClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";
import {
  ANON_KEY,
  SUPABASE_URL,
  admin,
  createOrganization,
  createSignedInUser,
} from "./helpers";

// issue_activation_continuation() is called from /activar/continuar with NO
// Supabase session yet (that is the whole point of ADR-0040), so the real
// caller carries only the anon key. This client reproduces that.
const anon = createClient(SUPABASE_URL, ANON_KEY);

async function issueCustomerActivationToken(displayName: string, phone: string) {
  const owner = await createSignedInUser("owner-continuation");
  const org = await createOrganization(owner, "org-continuation");

  const { data: customer, error: createErr } = await owner.client.rpc("create_managed_customer", {
    p_organization_id: org.id,
    p_display_name: displayName,
    p_phone: phone,
  });
  expect(createErr).toBeNull();

  const { data: issued, error: issueErr } = await owner.client.rpc("issue_customer_activation", {
    p_customer_id: customer!.id,
  });
  expect(issueErr).toBeNull();
  const row = Array.isArray(issued) ? issued[0] : issued;

  return {
    owner,
    org,
    customerId: customer!.id as string,
    activationId: row.activation_id as string,
    token: row.token as string,
  };
}

describe("Phase 40 -- activation continuation nonce (ADR-0040)", () => {
  it("issues a nonce (anon-callable) and redeems it exactly once for the real token", async () => {
    const { token } = await issueCustomerActivationToken(
      "Continuación Feliz",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { data: nonce, error: issueContErr } = await anon.rpc("issue_activation_continuation", {
      p_token: token,
    });
    expect(issueContErr).toBeNull();
    expect(typeof nonce).toBe("string");
    expect((nonce as string).length).toBeGreaterThan(20);
    // The nonce is never the token itself -- it is a wholly separate secret.
    expect(nonce).not.toBe(token);

    const { data: redeemed, error: redeemErr } = await anon.rpc("redeem_activation_continuation", {
      p_nonce: nonce,
    });
    expect(redeemErr).toBeNull();
    expect(redeemed).toBe(token);

    // Second attempt with the same nonce, immediately after: must fail.
    const { data: secondRedeem, error: secondErr } = await anon.rpc("redeem_activation_continuation", {
      p_nonce: nonce,
    });
    expect(secondRedeem).toBeNull();
    expect(secondErr).not.toBeNull();
    expect(secondErr!.message).toMatch(/INVALID_CONTINUATION/);
  });

  it("an expired nonce fails to redeem", async () => {
    const { activationId, token } = await issueCustomerActivationToken(
      "Continuación Vencida",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { data: nonce, error: issueContErr } = await anon.rpc("issue_activation_continuation", {
      p_token: token,
    });
    expect(issueContErr).toBeNull();

    // Force the row into the past directly via the service role (there is
    // no policy on this table for anyone else -- same access model as
    // customer_activations). Looked up by activation_id, which the test
    // already has from issuing the underlying activation, rather than by
    // nonce_hash, which only Postgres (via pgcrypto) can compute.
    const { error: backdateErr } = await admin
      .from("customer_activation_continuations")
      .update({ expires_at: new Date(Date.now() - 1_000).toISOString() })
      .eq("activation_id", activationId);
    expect(backdateErr).toBeNull();

    const { data: redeemed, error: redeemErr } = await anon.rpc("redeem_activation_continuation", {
      p_nonce: nonce,
    });
    expect(redeemed).toBeNull();
    expect(redeemErr).not.toBeNull();
    expect(redeemErr!.message).toMatch(/INVALID_CONTINUATION/);
  });

  it("a nonce that never existed fails to redeem, with the same generic error", async () => {
    const { error: redeemErr } = await anon.rpc("redeem_activation_continuation", {
      p_nonce: "this-nonce-was-never-issued-by-anyone-ever",
    });
    expect(redeemErr).not.toBeNull();
    expect(redeemErr!.message).toMatch(/INVALID_CONTINUATION/);
  });

  it("issuing a continuation for an invalid/unknown token fails, same vocabulary as the token flow", async () => {
    const { error } = await anon.rpc("issue_activation_continuation", {
      p_token: "not-a-real-activation-token",
    });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVALID_TOKEN/);
  });

  it("issuing a continuation for a revoked activation fails", async () => {
    const { owner, activationId, token } = await issueCustomerActivationToken(
      "Continuación Revocada",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { error: revokeErr } = await owner.client.rpc("revoke_customer_activation", {
      p_activation_id: activationId,
    });
    expect(revokeErr).toBeNull();

    const { error } = await anon.rpc("issue_activation_continuation", { p_token: token });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/ACTIVATION_REVOKED/);
  });

  // ADR-0040 "Corrección post-review de seguridad": the original ADR text
  // claimed claim_customer_activation() required the session's email to
  // match the invited customer's -- security-engineer proved that premise
  // false, live. claim_customer_activation() (Phase 21) only ever checks
  // `auth.uid() is not null`; it has no email to compare against (managed
  // customers do not carry one). So redeeming a continuation and then
  // claiming with ANY authenticated account succeeds -- this is not a gap
  // introduced by this migration, it is the pre-existing behaviour of
  // claim_customer_activation() itself, now exercised end-to-end through
  // the continuation nonce. The ADR accepts this: possessing the nonce (or
  // the underlying token) is, and always was, the entire authorization --
  // same threat model as the WhatsApp link itself (ADR-0026).
  it("redeeming a nonce and claiming with an unrelated account succeeds -- intentional, not a bug (see ADR-0040)", async () => {
    const { token } = await issueCustomerActivationToken(
      "Continuación Cuenta Distinta",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { data: nonce, error: issueContErr } = await anon.rpc("issue_activation_continuation", {
      p_token: token,
    });
    expect(issueContErr).toBeNull();

    const { data: redeemedToken, error: redeemErr } = await anon.rpc(
      "redeem_activation_continuation",
      { p_nonce: nonce },
    );
    expect(redeemErr).toBeNull();
    expect(redeemedToken).toBe(token);

    // An account with zero relationship to the invited customer or its
    // organization -- not even signed up with the same email.
    const stranger = await createSignedInUser("stranger-claims-continuation");

    const { data: claimed, error: claimErr } = await stranger.client.rpc(
      "claim_customer_activation",
      { p_token: redeemedToken },
    );
    expect(claimErr).toBeNull();
    expect((claimed as { status: string }).status).toBe("OK");

    const { data: customerRow, error: readErr } = await admin
      .from("customers")
      .select("profile_id")
      .eq("id", (claimed as { customer_id: string }).customer_id)
      .single();
    expect(readErr).toBeNull();
    expect(customerRow!.profile_id).toBe(stranger.id);
  });

  it("the raw activation_token_enc column never holds the clear token, even mid-flight (post-issue, pre-redeem)", async () => {
    const { activationId, token } = await issueCustomerActivationToken(
      "Continuación Cifrada",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { error: issueContErr } = await anon.rpc("issue_activation_continuation", {
      p_token: token,
    });
    expect(issueContErr).toBeNull();

    // Service role bypasses RLS, same as the backdate in the expired-nonce
    // test above -- this is exactly the "read the raw row" the security
    // review asked for.
    const { data: rows, error: readErr } = await admin
      .from("customer_activation_continuations")
      .select("activation_token_enc")
      .eq("activation_id", activationId);
    expect(readErr).toBeNull();
    expect(rows).toHaveLength(1);

    const raw = rows![0]!.activation_token_enc as string;
    expect(raw).not.toBeNull();
    // PostgREST serializes bytea as a hex string prefixed with \x (Postgres
    // default bytea_output=hex) -- decode it back to bytes and confirm the
    // clear token does not appear anywhere in them, under either common
    // text encoding. AES-256/OpenPGP ciphertext containing the exact
    // plaintext as a substring is not a real risk, but this is the direct
    // regression test for "did someone revert to storing the clear token".
    const hex = raw.startsWith("\\x") ? raw.slice(2) : raw;
    const buf = Buffer.from(hex, "hex");
    expect(buf.length).toBeGreaterThan(0);
    expect(buf.toString("utf8")).not.toContain(token);
    expect(buf.toString("latin1")).not.toContain(token);
    expect(raw).not.toContain(token);
  });

  it("TOO_MANY_CONTINUATIONS on an 11th live nonce for the same activation", async () => {
    const { token } = await issueCustomerActivationToken(
      "Continuación Límite",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    for (let i = 0; i < 10; i += 1) {
      const { error } = await anon.rpc("issue_activation_continuation", { p_token: token });
      expect(error).toBeNull();
    }

    const { data: eleventh, error: eleventhErr } = await anon.rpc(
      "issue_activation_continuation",
      { p_token: token },
    );
    expect(eleventh).toBeNull();
    expect(eleventhErr).not.toBeNull();
    expect(eleventhErr!.message).toMatch(/TOO_MANY_CONTINUATIONS/);
  });

  it("redeeming a nonce whose activation was revoked after issuance fails with the same generic error", async () => {
    const { owner, activationId, token } = await issueCustomerActivationToken(
      "Continuación Revocada Post-Emisión",
      `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
    );

    const { data: nonce, error: issueContErr } = await anon.rpc("issue_activation_continuation", {
      p_token: token,
    });
    expect(issueContErr).toBeNull();

    const { error: revokeErr } = await owner.client.rpc("revoke_customer_activation", {
      p_activation_id: activationId,
    });
    expect(revokeErr).toBeNull();

    const { data: redeemed, error: redeemErr } = await anon.rpc("redeem_activation_continuation", {
      p_nonce: nonce,
    });
    expect(redeemed).toBeNull();
    expect(redeemErr).not.toBeNull();
    expect(redeemErr!.message).toMatch(/INVALID_CONTINUATION/);
  });
});
