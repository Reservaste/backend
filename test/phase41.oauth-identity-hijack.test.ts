// Fase 41 -- verificación de integración del trigger que cierra el camino 2
// de la corrección post-review de ADR-0043 (docs/decisions.md, docs/security.md
// "Fase 41"): backend/supabase/migrations/20260929140000_phase41_adr0043_post_review_hardening.sql,
// función public.check_identity_link_not_oauth_hijack() + trigger
// auth_identities_block_oauth_hijack (`before insert on auth.identities`).
//
// Hasta ahora esto solo se había verificado a mano contra Supabase local, por
// dos agentes distintos (ver comentario de la migración), sin quedar fijado
// como test permanente -- hallazgo B1 del segundo pase de seguridad.
//
// Por qué esto NO se puede probar con el cliente service_role de
// `test/helpers.ts` como el resto de la suite (Fase 21/33 y compañía): ese
// cliente habla con la DB por dos caminos, y ninguno alcanza:
//   - PostgREST (`admin.from(...)`) solo expone los schemas `public` y
//     `graphql_public` (backend/supabase/config.toml, [api] schemas) -- el
//     schema `auth` no tiene API REST, con o sin service_role.
//   - GoTrueAdminApi (`admin.auth.admin.*`) no tiene ningún método para
//     insertar o actualizar una fila de `auth.identities` a mano -- se
//     confirmó en vivo que `createUser({ ..., identities: [...] })` IGNORA
//     ese campo (GoTrue solo crea la identidad `email` automática cuando hay
//     contraseña) y no existe equivalente admin de `linkIdentity()` (esa es
//     una operación de sesión de usuario, pensada para el flujo real de
//     OAuth con navegador).
// La única superficie que de verdad inserta o actualiza filas en
// `auth.identities` sin pasar por un login real de Google es una conexión
// directa a Postgres -- el mismo camino que ya usa `supabase db
// reset`/`db push` contra `127.0.0.1:54322` (backend/supabase/config.toml,
// [db] port), disponible tanto en local como en el runner de CI (`supabase
// start` publica ese puerto en el host, no dentro de un contenedor propio;
// confirmado en vivo contra el stack local, incluido que el rol `postgres`
// tiene privilegio para escribir en `auth.identities` -- ADR-0043 ya apoya
// esto mismo para poder crear el trigger). `pg` se agrega como devDependency
// de `backend/` solo para este archivo de test.
import { randomUUID } from "node:crypto";
import { Client } from "pg";
import { afterAll, describe, expect, it } from "vitest";
import { admin, createSignedInUser, type SignedInUser } from "./helpers";

const DIRECT_DB_URL =
  process.env.SUPABASE_DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

/**
 * Corta conexión por operación en vez de un pool: son pocas llamadas por
 * test y evita dejar handles abiertos que compitan con los que usa
 * `supabase db reset` entre archivos.
 */
async function withDirectDb<T>(fn: (client: Client) => Promise<T>): Promise<T> {
  const client = new Client({ connectionString: DIRECT_DB_URL });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

async function insertGoogleIdentity(userId: string, email: string) {
  return withDirectDb((client) =>
    client.query(
      `insert into auth.identities
         (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
       values
         (gen_random_uuid(), $1::uuid,
          jsonb_build_object('sub', $1::text, 'email', $2::text, 'email_verified', true),
          'google', $1::text, now(), now(), now())`,
      [userId, email],
    ),
  );
}

async function deleteEmailIdentity(userId: string) {
  return withDirectDb((client) =>
    client.query(`delete from auth.identities where user_id = $1 and provider = 'email'`, [userId]),
  );
}

async function countIdentities(userId: string): Promise<number> {
  const result = await withDirectDb((client) =>
    client.query<{ count: string }>(`select count(*)::text as count from auth.identities where user_id = $1`, [
      userId,
    ]),
  );
  return Number(result.rows[0]!.count);
}

describe("Fase 41 -- trigger auth_identities_block_oauth_hijack (ADR-0043, corrección post-review)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("bloquea insertar una identidad google sobre un user_id que ya tiene una identidad email", async () => {
    // createSignedInUser() crea el usuario vía admin.auth.admin.createUser()
    // con password -- GoTrue le arma automáticamente la identidad `email`.
    const victim: SignedInUser = await createSignedInUser("p41-hijack-victim");
    createdUserIds.push(victim.id);

    const before = await countIdentities(victim.id);
    expect(before).toBe(1);

    await expect(insertGoogleIdentity(victim.id, victim.email)).rejects.toMatchObject({
      message: expect.stringContaining("OAUTH_LINK_BLOCKED_EXISTING_PASSWORD_IDENTITY"),
    });

    // El insert bloqueado no dejó nada a medio camino: sigue exactamente
    // con la única identidad `email` que tenía antes.
    const after = await countIdentities(victim.id);
    expect(after).toBe(1);
  });

  it("permite insertar una identidad google sobre un user_id NUEVO sin ninguna identidad previa", async () => {
    const freshLogin: SignedInUser = await createSignedInUser("p41-fresh-google");
    createdUserIds.push(freshLogin.id);

    // Deja al usuario sin identidades -- reproduce "user_id nuevo, sin
    // ninguna identidad previa" sin tener que insertar a mano una fila
    // completa de auth.users (con todas sus columnas y su propio trigger
    // on_auth_user_created) para lograr el mismo estado.
    await deleteEmailIdentity(freshLogin.id);
    expect(await countIdentities(freshLogin.id)).toBe(0);

    await expect(insertGoogleIdentity(freshLogin.id, freshLogin.email)).resolves.toBeTruthy();

    const after = await countIdentities(freshLogin.id);
    expect(after).toBe(1);
  });

  it("permite el UPDATE de una identidad google ya existente sobre un user_id que también tiene email (login posterior normal)", async () => {
    const bothLinked: SignedInUser = await createSignedInUser("p41-both-linked");
    createdUserIds.push(bothLinked.id);
    expect(await countIdentities(bothLinked.id)).toBe(1); // solo `email`, por ahora.

    // Vincula google "legítimamente" ANTES de que exista la identidad email
    // (mismo truco que el caso anterior: sin identidad email todavía, el
    // insert de google no dispara la guarda), y recién después re-agrega la
    // identidad email -- el trigger nunca corre sobre un insert de
    // provider = 'email'. El estado final -- un user_id con las dos
    // identidades vinculadas -- es indistinguible del que deja un vínculo
    // real y legítimo hecho en su momento.
    await deleteEmailIdentity(bothLinked.id);
    await insertGoogleIdentity(bothLinked.id, bothLinked.email);
    await withDirectDb((client) =>
      client.query(
        `insert into auth.identities
           (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
         values
           (gen_random_uuid(), $1::uuid,
            jsonb_build_object('sub', $1::text, 'email', $2::text, 'email_verified', true),
            'email', $1::text, now(), now(), now())`,
        [bothLinked.id, bothLinked.email],
      ),
    );
    expect(await countIdentities(bothLinked.id)).toBe(2);

    // El caso real: un login posterior con "Continuar con Google" no
    // inserta una fila nueva, GoTrue hace UPDATE de la identidad google que
    // ya existe (last_sign_in_at, identity_data, updated_at). El trigger es
    // `before insert`, así que esto tiene que pasar limpio.
    const newSub = randomUUID();
    await expect(
      withDirectDb((client) =>
        client.query(
          `update auth.identities
             set last_sign_in_at = now(),
                 updated_at = now(),
                 identity_data = jsonb_set(identity_data, '{sub}', to_jsonb($2::text))
           where user_id = $1 and provider = 'google'`,
          [bothLinked.id, newSub],
        ),
      ),
    ).resolves.toBeTruthy();

    // Las dos identidades siguen ahí, nada se perdió ni se duplicó.
    expect(await countIdentities(bothLinked.id)).toBe(2);
  });
});
