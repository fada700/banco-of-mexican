
# Plan: MDT + Sueldos + Impuestos + Membresías 7 niveles

## Decisiones confirmadas
- Reemplazar membresías viejas (basica/plus/black) por 7 nuevas, todos migran a `basica`.
- Nuevo rol Discord `policia` para MDT.
- Sueldos configurables por rol Discord.
- Impuestos cada 6 días, % sobre `saldo_banco`. Si no alcanza → queda deuda (`impuestos_pendientes`) que se cobra del próximo ingreso.

## Lo que necesito de ti antes de implementar
1. **ROLE_ID_POLICIA** (Discord role ID para el rol de policía).
2. **7 Role IDs de Discord** para las membresías: Básica, Gold, Zafiro, Esmeralda, Diamond, Ruby, Ruby+. (Si no los tienes aún, los puedo dejar configurables desde tabla `config_membresias` y los agregas luego.)
3. **Tasa de impuestos**: ¿fijo 20%, o variable según membresía? (Sugiero variable: Básica 25%, Gold 22%, Zafiro 20%, Esmeralda 18%, Diamond 15%, Ruby 12%, Ruby+ 10%.)
4. **Tabla de sueldos por rol**: dime cuánto cobra `policia`, `trabajador`, `admin` y cada cuántos días. (Sugiero: policia 50,000 c/7d; trabajador 75,000 c/7d; admin 0 — confírmame.)

## Cambios de BD (migración)

### Enums nuevos
- `tipo_membresia` → reemplazar valores: `basica, gold, zafiro, esmeralda, diamond, ruby, ruby_plus`
- Nuevo en `app_role`: agregar `policia`
- Nuevo `tipo_movimiento`: `multa, pago_multa, sueldo, impuesto, compra_membresia`
- Nuevo `estado_multa`: `pendiente, pagada, cancelada`

### Tablas nuevas
- **`config_membresias`** (1 fila por nivel): `tipo`, `costo`, `tx_diarias`, `tx_grandes_diarias`, `monto_grande`, `debito_max`, `cartera_max`, `credito_max`, `seguridad_antihackeo_pct`, `seguro_dinero_pct`, `nivel_soporte`, `role_id_discord`, `impuesto_pct`
- **`multas`**: `id`, `usuario_id`, `policia_id`, `monto`, `motivo`, `estado` (pendiente/pagada/cancelada), `fecha_emision`, `fecha_pago`
- **`config_sueldos`**: `role` (app_role), `monto`, `dias_periodo`
- **`sueldos_reclamados`**: `id`, `usuario_id`, `role`, `monto`, `fecha`
- Columnas nuevas en `usuarios`: `impuestos_pendientes numeric default 0`, `ultimo_impuesto_en timestamptz`

### Funciones nuevas
- `emitir_multa(_usuario_id, _monto, _motivo)` — solo policia/admin
- `pagar_multa(_multa_id)` — usuario; saldo_banco → ganancias_banco (gobierno)
- `cancelar_multa(_multa_id)` — policia/admin
- `reclamar_sueldo()` — usuario; verifica rol + periodo, descuenta de ganancias_banco; si no hay fondos → error "Gobierno sin fondos"
- `comprar_membresia(_tipo)` — descuenta costo de saldo_banco, envía al dueño, actualiza membresía, dispara notificación con role Discord a agregar
- `cobrar_impuestos_tick()` — itera usuarios activos; si `now() - ultimo_impuesto_en >= 6d`: monto = saldo_banco * pct; descuenta lo que pueda; resto a `impuestos_pendientes`; lo cobrado va a `ganancias_banco`
- Trigger en `movimientos` (o llamado desde transferencia/depósito): si usuario tiene `impuestos_pendientes > 0` y le entra dinero, se descuenta primero.

### Cron
- `/api/public/cron-impuestos` cada 24h llamando `cobrar_impuestos_tick()`. Programado vía `pg_cron`.

### Limites de transacción
- Función `check_limite_transaccion(_usuario_id, _monto)` validada en `op_transferir`, `op_retirar`, etc. Cuenta tx del día, valida vs membresía.

## Cambios frontend
- **`/_authenticated/mdt`** (nueva, solo policia/admin): emitir multa, lista de multas pendientes, recordatorio (DM Discord), historial.
- **`/_authenticated/perfil`**: agregar tarjeta "Reclamar sueldo" con countdown al siguiente cobro.
- **`/_authenticated/membresias`** (nueva): grid con los 7 niveles, botón Comprar (descuenta del banco, asigna rol Discord, DM).
- **`/_authenticated/home`**: mostrar `impuestos_pendientes` si > 0, próxima fecha de cobro, multas pendientes.
- **`/_authenticated/admin`**: panel para configurar sueldos, costos de membresía, % impuesto por nivel.
- **`/_authenticated/trabajador-panel`**: ver multas emitidas, marcar pagadas manualmente.
- Tarjeta débito/crédito cambia estética según membresía (gradiente por nivel).

## Notificaciones Discord (DM)
- Multa emitida / recordatorio cada 48h si pendiente
- Sueldo reclamado
- Impuesto cobrado / deuda generada
- Membresía comprada (+ otorgar rol Discord vía bot)
- Gobierno sin fondos (al policia/admin que intentó pagar sueldo)

## Roles Discord — sync
- Extender `resyncDiscordRoles` para incluir `policia` y mapear rol Discord ↔ membresía.
- Al comprar membresía: llamar a Discord API `PUT /guilds/{guild}/members/{user}/roles/{role}` para asignar; remover el anterior.

## Orden de implementación
1. Migración BD (enums, tablas, funciones, seed `config_membresias` y `config_sueldos`).
2. Secrets: `ROLE_ID_POLICIA` + role IDs membresías (si los tienes).
3. Backend: server functions (`mdt.functions.ts`, `sueldos.functions.ts`, `membresias.functions.ts`, `impuestos.server.ts`).
4. Cron job impuestos.
5. UI: rutas nuevas + integración en home/perfil/admin.
6. Discord role sync extendido.
7. QA: probar emisión multa → pago → ganancia banco; reclamar sueldo con/sin fondos; cobro impuesto con deuda; comprar membresía → cambio rol + estética.

## Riesgo / advertencias
- **Reemplazar enum `tipo_membresia`** rompe queries existentes; toca migrar todas las filas a `basica` antes y actualizar `types.ts` (auto).
- Si **no me pasas los role IDs ahora**, los dejo `NULL` en `config_membresias` y la asignación de roles Discord queda inactiva hasta que los cargues desde el panel admin.
- ~1000 usuarios × impuestos cada 6d = batch de hasta 1000 updates por tick; lo haré en un solo SQL atómico (`UPDATE ... FROM ...`) para que sea eficiente.

---

**Antes de ejecutar dime:**
- `ROLE_ID_POLICIA` =
- Role IDs membresías (o "déjalos NULL")
- Tasa impuestos (fija 20% o por nivel como sugerí)
- Sueldos (acepto mi sugerencia o dame tus valores)
