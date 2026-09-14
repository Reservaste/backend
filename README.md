# @reservaste/domain

Base de datos (Supabase/PostgreSQL) y paquete de dominio compartido de
Reservaste — plataforma SaaS multi-tenant de agenda, reservas, cupos
dinámicos, servicios habilitados, pagos y reservas recurrentes.

Este repo **no es un servicio HTTP**. La API vive en
[`Reservaste/frontend`](https://github.com/Reservaste/frontend) como
server actions/route handlers de Next.js, que hablan directo con Supabase
vía `supabase-js` y las funciones RPC definidas acá. Ver
`docs/decisions.md` (ADR-0002, ADR-0016) en el workspace de coordinación
del proyecto para el razonamiento completo.

## Contenido

- `supabase/migrations/` — schema SQL, RLS, triggers y funciones RPC.
  Fuente de verdad del modelo de datos, sin ORM (ADR-0002).
- `src/` — paquete `@reservaste/domain`: tipos TypeScript, esquemas Zod,
  invariantes de negocio puras y mappers entre las filas de Supabase
  (snake_case) y los tipos de dominio (camelCase). Consumido por el
  frontend como dependencia.

## Desarrollo local

Requiere [Supabase CLI](https://supabase.com/docs/guides/cli) y Docker.

```bash
npx supabase start        # levanta Postgres/Auth/Studio local
npx supabase db reset     # aplica las migraciones desde cero
npm install
npm run typecheck
npm test                  # unit tests (invariantes/schemas, sin DB)
npm run test:integration  # RLS cross-tenant contra el Supabase local (ADR-0006)
```

`test:integration` necesita `supabase start` corriendo. Usa por defecto
las credenciales demo fijas que imprime `supabase start` para un proyecto
local (nunca válidas contra un proyecto real) — se pueden sobreescribir
con `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` si tu
stack local corre en otro puerto.

## Convenciones

- Nunca introducir `Gym`/`Member`/`Trainer`/`Class` como conceptos
  centrales — la plataforma es genérica por diseño.
- Todo cambio de schema es una migración nueva versionada, nunca se edita
  una migración ya aplicada.
- Las operaciones que necesitan atomicidad (evitar overbooking, generar
  reservas recurrentes) se implementan como funciones RPC de PostgreSQL,
  no como lógica de aplicación — ver ADR-0004/ADR-0011.
