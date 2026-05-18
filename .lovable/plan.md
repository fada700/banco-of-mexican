
# Plan de implementación

Cambios grandes en 5 frentes. Lo divido en fases para ejecutar de abajo hacia arriba (DB → backend → frontend), tal como pediste.

---

## Fase 1 — Base de datos (migraciones)

### 1.1 Nuevas tablas

- **`audit_logs`**
  - `id`, `realizado_por_id` (uuid), `realizado_por_nombre`, `realizado_por_rol`
  - `accion` (text: `CONGELAR_CUENTA`, `DESCONGELAR_CUENTA`, `CERRAR_CUENTA`, `ABRIR_DEBITO`, `ABRIR_CREDITO`, `AJUSTAR_SALDO`, `APROBAR_CREDITO`, `RECHAZAR_CREDITO`, `AJUSTAR_LIMITE`, `CONDONAR_DEUDA`, `CAMBIAR_ROL`, `SET_DUENO`)
  - `entidad`, `entidad_id`, `cliente_nombre`
  - `detalle` (jsonb con antes/después/motivo/monto)
  - `ip_address` (text, opcional)
  - `fecha_hora` (timestamptz)
  - RLS: SELECT solo admin. INSERT/UPDATE/DELETE bloqueados desde cliente (solo se escribe vía `SECURITY DEFINER`).
  - Índices: `realizado_por_id`, `fecha_hora`, `entidad_id`.

- **`notification_log`**
  - `id`, `usuario_id`, `discord_user_id`, `tipo_notificacion`, `mensaje` (text), `estado` (`enviado` | `fallido`), `error` (text null), `enviado_en`.
  - RLS: usuario ve las suyas; admin ve todas.
  - Índices: `usuario_id`, `enviado_en`.

### 1.2 Cambios en tablas existentes

- `usuarios`: añadir `estado_cuenta` enum (`activa`, `congelada`, `cerrada`) default `activa`.
- `tarjetas_debito`: añadir `estado` enum (`activa`, `congelada`, `cerrada`) — la columna `congelada` actual se mantiene por compatibilidad pero el estado canónico pasa a ser `estado`.
- `tarjetas_credito`: ya tiene `estado` — añadir valor `cerrada` al enum.
- Añadir `clabe` (text, 18 dígitos) en `usuarios`, generada automáticamente al registrar (trigger).
- `tarjetas_credito`: añadir `fecha_corte` (timestamptz) calculada al usar crédito.

### 1.3 Constraints e índices

- `CHECK (saldo_banco >= 0)` y `CHECK (saldo_cartera >= 0)` en `usuarios`.
- Índices: `movimientos(usuario_id)`, `movimientos(fecha)`, `audit_logs(realizado_por_id)`, `audit_logs(fecha_hora)`, `notification_log(usuario_id)`.

### 1.4 Funciones nuevas / actualizadas (todas `SECURITY DEFINER` con check de rol)

- `log_audit(...)` helper interno.
- `congelar_cuenta(_usuario_id, _motivo)` → cambia `estado_cuenta` + escribe audit.
- `descongelar_cuenta(_usuario_id, _motivo)`.
- `cerrar_cuenta(_usuario_id, _motivo)` → marca usuario y tarjetas como `cerrada`, bloquea operaciones futuras.
- `abrir_tarjeta_debito_manual(_usuario_id, _motivo)`, `abrir_tarjeta_credito_manual(_usuario_id, _limite, _motivo)`.
- Modificar `op_depositar`, `op_retirar`, `op_transferir`, `usar_credito`, `pagar_credito` para **rechazar** si `estado_cuenta` ≠ `activa`. Ya son atómicas.
- Modificar `admin_ajustar_saldo`, `aprobar_tarjeta_credito`, `rechazar_tarjeta_credito`, `ajustar_limite_credito`, `condonar_deuda` para llamar `log_audit`.
- Trigger en `usuarios` que llene `clabe` (18 dígitos) en INSERT.

### 1.5 RLS

Revisar todas las tablas y endurecer:
- `usuarios`, `movimientos`, `tarjetas_debito`, `tarjetas_credito`, `solicitudes`, `membresias`, `ganancias_banco`, `config`, `roles_usuario` ya tienen RLS — verificar y completar políticas faltantes (INSERT/UPDATE/DELETE explícitas) y añadir las de las dos tablas nuevas.

---

## Fase 2 — Backend (server functions)

### 2.1 Notificaciones Discord (`src/lib/notifications.server.ts`)

- `sendDiscordDM(discord_user_id, mensaje)` usando `DISCORD_BOT_TOKEN` (ya existe). Flujo: `POST /users/@me/channels` para abrir DM → `POST /channels/{id}/messages`.
- Wrapper `notify(usuario_id, tipo, mensaje)` que envía + registra en `notification_log`.
- Disparadores invocados desde server functions tras éxito de:
  - `op_depositar`, `op_retirar`, `op_transferir` (origen y destino), `usar_credito`, `pagar_credito`
  - `aprobar_tarjeta_credito`, `rechazar_tarjeta_credito`
  - `congelar_cuenta`, `cerrar_cuenta`

### 2.2 Recordatorios de pago de crédito (7 días / 1 día)

- Nuevo endpoint público `src/routes/api/public/cron-credit-reminders.ts` que escanea tarjetas con `fecha_limite_pago` entre hoy+1 y hoy+7 y envía DM. Protegido con header `X-Cron-Secret` (nuevo secreto `CRON_SECRET` — **te diré que lo añadas tú**).
- pg_cron lo invoca cada día (o el usuario lo programa donde quiera).

### 2.3 Nuevas server functions de staff (`src/lib/staff.functions.ts`)

- `listarClientes({ q, page })` con paginación.
- `getClienteDetalle(usuario_id)` → perfil, tarjetas, últimas 10 transacciones.
- `congelarCuenta`, `descongelarCuenta`, `cerrarCuenta`, `abrirDebito`, `abrirCredito` (cada una pide `motivo`).
- `listarMorosos` (mejora del actual `listarDeudores` con `dias_vencidos` y % utilizado).

### 2.4 Server functions de admin

- `listarAuditLogs({ filtros, page })` con paginación 50/pág.
- `exportarAuditCSV(filtros)` → devuelve string CSV.

### 2.5 Estado de cuenta + PDF

- `getEstadoCuenta({ desde, hasta, tipo?, tarjeta? })` → resumen + movimientos con saldo acumulado calculado.
- PDF se genera **en el cliente** con `jsPDF` + `jspdf-autotable` (evita pesados PDF en el Worker). Componente que toma los datos del server function y produce el PDF.

---

## Fase 3 — Frontend

### 3.1 PWA (manifest-only, sin service worker)

- `public/manifest.json` ya existe. Añadir `<link rel="manifest">`, meta tags de Apple (`apple-mobile-web-app-capable`, `apple-touch-icon`) en `__root.tsx`.
- Sin `vite-plugin-pwa` ni service workers (regla Lovable: rompen el preview).
- Funciona como "Add to Home Screen" en iOS y Android.

### 3.2 Estado de cuenta (usuario)

- Nueva ruta `/_authenticated/estado-cuenta.tsx`.
- Filtros: rango fechas, tipo, tarjeta. Tabla con saldo después.
- Botón "Descargar PDF": logo, datos cliente, tabla, saldo final. Para crédito incluye fecha límite, pago mínimo (5% saldo_usado), total.
- Link desde `home.tsx`.

### 3.3 Rediseño panel trabajador

Reescribir `_authenticated/trabajador-panel.tsx` con estética banca corporativa:
- Paleta navy/grafito (tokens nuevos en `styles.css`).
- Tabs: **Clientes** | **Solicitudes** | **Morosos**.
- **Clientes**: tabla paginada + buscador → click abre `Sheet` (drawer) con perfil, ambas tarjetas, últimas 10 tx y botones de acción. Cada acción abre modal pidiendo motivo. "Cerrar cuenta" pide escribir `CONFIRMAR`.
- **Solicitudes** y **Morosos**: mantienen lógica, rediseñadas a la nueva estética.

### 3.4 Panel admin — Auditoría

- Nueva tab/sección en `_authenticated/admin.tsx`: "Auditoría".
- Tabla paginada (50/pág), filtros (trabajador, acción, fechas, cliente), filas expandibles con JSON, botón "Exportar CSV".
- Solo lectura (no botones de editar/borrar).

### 3.5 Seguridad de rutas

- `_authenticated.tsx` ya gatea sesión. Añadir guard de rol:
  - `/admin` → solo `admin`.
  - `/trabajador-panel` → `admin` o `trabajador`.
  - Cliente sin rol staff que intente entrar → redirect a `/home`.

---

## Fase 4 — Cosas que tú debes hacer manualmente

Te las listo al final del trabajo. Adelanto:

1. **Añadir secreto `CRON_SECRET`** (string aleatorio largo) en Cloud → Secrets, para proteger el cron de recordatorios.
2. **Programar el cron** (pg_cron o servicio externo) que llame `POST https://banco-of-mexican.lovable.app/api/public/cron-credit-reminders` con header `X-Cron-Secret: <valor>` una vez al día.
3. Verificar que el bot de Discord tenga permiso de **enviar DMs** y esté en el servidor con los miembros visibles.

---

## Detalles técnicos relevantes

- **Stack**: TanStack Start + Supabase (Lovable Cloud). Server functions vía `createServerFn`, server routes para webhooks/cron.
- **Atomicidad**: Las operaciones financieras siguen vía RPC PostgreSQL (`op_*`) con `SELECT ... FOR UPDATE`, lo que ya garantiza rollback en error.
- **`SECURITY DEFINER`**: todas las funciones nuevas validan rol con `has_role()` antes de actuar.
- **PDF**: cliente con `jsPDF` (peso aceptable, evita issues de Workers).
- **CLABE**: generada `'6461801'` (prefijo BANCO) + 11 dígitos aleatorios = 18 dígitos, único por usuario.
- **Notificación Discord**: si falla el DM (usuario bloqueó DMs), se registra `estado='fallido'` con `error`, no rompe la transacción.
- **Pago mínimo crédito**: 5% del `saldo_usado` (configurable más tarde si quieres otro %).

---

## Orden de ejecución

1. Migración SQL completa (Fase 1).
2. Server functions + Discord notifier + cron route (Fase 2).
3. PWA meta tags + estado de cuenta + PDF (Fase 3.1–3.2).
4. Rediseño trabajador (Fase 3.3).
5. Auditoría admin (Fase 3.4).
6. Guards de ruta por rol (Fase 3.5).
7. Te paso checklist de secretos/cron pendientes.

¿Apruebas? Si quieres ajustar algo (p. ej. % de pago mínimo, prefijo CLABE, omitir alguna sección), dímelo antes de arrancar.
