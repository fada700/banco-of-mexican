import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { notify, formatMoney } from "@/lib/notifications.server";
import { z } from "zod";
import type { Database } from "@/integrations/supabase/types";

type TipoMovimiento = Database["public"]["Enums"]["tipo_movimiento"];

const montoSchema = z.number().positive().max(10_000_000);

async function usuarioIdFromAuth(authUserId: string): Promise<string> {
  const { data, error } = await supabaseAdmin
    .from("usuarios")
    .select("id")
    .eq("auth_user_id", authUserId)
    .single();
  if (error || !data) throw new Error("Usuario no encontrado");
  return data.id;
}

async function getSaldo(uid: string) {
  const { data } = await supabaseAdmin.from("usuarios").select("saldo_banco").eq("id", uid).single();
  return Number(data?.saldo_banco ?? 0);
}

export const depositar = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { monto: number }) =>
    z.object({ monto: montoSchema }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const { error } = await context.supabase.rpc("op_depositar", { _monto: data.monto });
    if (error) throw new Error(error.message);
    const uid = await usuarioIdFromAuth(context.userId);
    const saldo = await getSaldo(uid);
    notify({
      usuario_id: uid, tipo: "transaccion", color: 0x16a34a,
      titulo: "Depósito recibido",
      descripcion: `Se depositaron ${formatMoney(data.monto)} a tu cuenta bancaria.`,
      fields: [{ name: "Saldo actual", value: formatMoney(saldo), inline: true }],
    }).catch(() => {});
    return { ok: true };
  });

export const retirar = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { monto: number }) =>
    z.object({ monto: montoSchema }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const { error } = await context.supabase.rpc("op_retirar", { _monto: data.monto });
    if (error) throw new Error(error.message);
    const uid = await usuarioIdFromAuth(context.userId);
    const saldo = await getSaldo(uid);
    notify({
      usuario_id: uid, tipo: "transaccion", color: 0xea580c,
      titulo: "Retiro",
      descripcion: `Retiraste ${formatMoney(data.monto)} de tu cuenta bancaria.`,
      fields: [{ name: "Saldo actual", value: formatMoney(saldo), inline: true }],
    }).catch(() => {});
    return { ok: true };
  });

export const transferir = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { destino: string; monto: number; concepto?: string }) =>
    z.object({
      destino: z.string().min(1).max(20).regex(/^[A-Z0-9-]+$/i),
      monto: montoSchema,
      concepto: z.string().max(80).optional(),
    }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const { data: result, error } = await context.supabase.rpc("op_transferir", {
      _destino_numero: data.destino.toUpperCase(),
      _monto: data.monto,
      _concepto: data.concepto ?? "",
    });
    if (error) throw new Error(error.message);
    const r = result as unknown as {
      monto: number; comision: number; total: number;
      destino_nombre: string; destino_numero: string; destino_id: string;
    };
    const uid = await usuarioIdFromAuth(context.userId);
    const saldoOrigen = await getSaldo(uid);
    const saldoDest = await getSaldo(r.destino_id);
    notify({
      usuario_id: uid, tipo: "transaccion", color: 0xea580c,
      titulo: "Transferencia enviada",
      descripcion: `Enviaste ${formatMoney(r.monto)} a ${r.destino_nombre}.`,
      fields: [
        { name: "Comisión", value: formatMoney(r.comision), inline: true },
        { name: "Saldo actual", value: formatMoney(saldoOrigen), inline: true },
      ],
    }).catch(() => {});
    notify({
      usuario_id: r.destino_id, tipo: "transaccion", color: 0x16a34a,
      titulo: "Transferencia recibida",
      descripcion: `Recibiste ${formatMoney(r.monto)}${data.concepto ? ` — ${data.concepto}` : ""}.`,
      fields: [{ name: "Saldo actual", value: formatMoney(saldoDest), inline: true }],
    }).catch(() => {});
    return r;
  });

export const toggleTarjeta = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const { data, error } = await context.supabase.rpc("toggle_tarjeta_debito");
    if (error) throw new Error(error.message);
    return { congelada: data as boolean };
  });

export const verificarCvv = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { cvv: string }) =>
    z.object({ cvv: z.string().regex(/^\d{3}$/) }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const uid = await usuarioIdFromAuth(context.userId);
    const { data: row } = await supabaseAdmin
      .from("tarjetas_debito")
      .select("cvv, congelada")
      .eq("usuario_id", uid)
      .maybeSingle();
    if (!row) throw new Error("No tienes tarjeta de débito");
    if (row.congelada) throw new Error("Tu tarjeta está congelada");
    if (row.cvv !== data.cvv) throw new Error("CVV incorrecto");
    return { ok: true };
  });

export interface Movimiento {
  id: string;
  tipo: TipoMovimiento;
  monto: number;
  descripcion: string;
  fecha: string;
}

const ENTRADAS: TipoMovimiento[] = ["deposito", "transferencia_recibida", "admin_dar", "condonacion"];
const SALIDAS: TipoMovimiento[] = ["retiro", "transferencia_enviada", "comision", "membresia", "uso_credito", "admin_quitar", "interes_credito", "pago_credito"];

export const listarMovimientos = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { filtro?: "todos" | "entradas" | "salidas" } | undefined) =>
    z.object({ filtro: z.enum(["todos", "entradas", "salidas"]).optional() }).parse(d ?? {}),
  )
  .handler(async ({ data, context }): Promise<Movimiento[]> => {
    const uid = await usuarioIdFromAuth(context.userId);

    let q = supabaseAdmin
      .from("movimientos")
      .select("id, tipo, monto, descripcion, fecha")
      .eq("usuario_id", uid)
      .order("fecha", { ascending: false })
      .limit(200);

    if (data.filtro === "entradas") q = q.in("tipo", ENTRADAS);
    else if (data.filtro === "salidas") q = q.in("tipo", SALIDAS);

    const { data: rows, error } = await q;
    if (error) throw new Error(error.message);
    return (rows ?? []).map((r) => ({
      id: r.id,
      tipo: r.tipo,
      monto: Number(r.monto),
      descripcion: r.descripcion,
      fecha: r.fecha,
    }));
  });

export function esEntrada(tipo: string): boolean {
  return (ENTRADAS as string[]).includes(tipo);
}

export interface EstadoCuentaRow {
  id: string;
  fecha: string;
  tipo: TipoMovimiento;
  descripcion: string;
  monto: number;
  signo: "abono" | "cargo";
  saldo_despues: number;
}

export interface EstadoCuentaResult {
  cliente: { nombre: string; numero_cliente: string; clabe: string | null };
  periodo: { desde: string; hasta: string };
  saldo_inicial: number;
  saldo_final: number;
  total_abonos: number;
  total_cargos: number;
  rows: EstadoCuentaRow[];
  credito: {
    estado: string;
    limite: number;
    saldo_usado: number;
    pago_minimo: number;
    fecha_limite_pago: string | null;
  } | null;
}

export const getEstadoCuenta = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { desde: string; hasta: string; filtro?: "todos" | "entradas" | "salidas" }) =>
    z.object({
      desde: z.string().min(8).max(40),
      hasta: z.string().min(8).max(40),
      filtro: z.enum(["todos", "entradas", "salidas"]).optional(),
    }).parse(d),
  )
  .handler(async ({ data, context }): Promise<EstadoCuentaResult> => {
    const uid = await usuarioIdFromAuth(context.userId);
    const { data: u } = await supabaseAdmin
      .from("usuarios").select("nombre, numero_cliente, clabe, saldo_banco").eq("id", uid).single();
    if (!u) throw new Error("Usuario no encontrado");

    // Movimientos del rango (ascendente para calcular saldo acumulado)
    const { data: rows } = await supabaseAdmin
      .from("movimientos")
      .select("id, tipo, monto, descripcion, fecha")
      .eq("usuario_id", uid)
      .gte("fecha", data.desde)
      .lte("fecha", data.hasta)
      .order("fecha", { ascending: true })
      .limit(2000);

    // Saldo posterior a hasta — para calcular saldo_inicial restando movimientos posteriores
    const saldoActual = Number(u.saldo_banco);
    const { data: posteriores } = await supabaseAdmin
      .from("movimientos")
      .select("tipo, monto")
      .eq("usuario_id", uid)
      .gt("fecha", data.hasta);
    let saldoFinal = saldoActual;
    for (const m of posteriores ?? []) {
      const monto = Number(m.monto);
      if ((ENTRADAS as string[]).includes(m.tipo)) saldoFinal -= monto;
      else if ((SALIDAS as string[]).includes(m.tipo)) saldoFinal += monto;
    }
    // saldoFinal = saldo al cierre de "hasta"
    let acumulado = saldoFinal;
    // recorrer rows desc para encontrar saldo_inicial
    const rowsDesc = [...(rows ?? [])].reverse();
    const saldosDespues: Record<string, number> = {};
    for (const m of rowsDesc) {
      saldosDespues[m.id] = acumulado;
      const monto = Number(m.monto);
      if ((ENTRADAS as string[]).includes(m.tipo)) acumulado -= monto;
      else if ((SALIDAS as string[]).includes(m.tipo)) acumulado += monto;
    }
    const saldoInicial = acumulado;

    let totalAbonos = 0, totalCargos = 0;
    const filtrados = (rows ?? []).filter((r) => {
      if (data.filtro === "entradas") return (ENTRADAS as string[]).includes(r.tipo);
      if (data.filtro === "salidas") return (SALIDAS as string[]).includes(r.tipo);
      return true;
    });
    const finalRows: EstadoCuentaRow[] = filtrados.map((r) => {
      const monto = Number(r.monto);
      const isAbono = (ENTRADAS as string[]).includes(r.tipo);
      if (isAbono) totalAbonos += monto; else totalCargos += monto;
      return {
        id: r.id, fecha: r.fecha, tipo: r.tipo, descripcion: r.descripcion,
        monto, signo: isAbono ? "abono" : "cargo",
        saldo_despues: saldosDespues[r.id] ?? 0,
      };
    });

    const { data: tc } = await supabaseAdmin
      .from("tarjetas_credito")
      .select("estado, limite, saldo_usado, fecha_limite_pago")
      .eq("usuario_id", uid).maybeSingle();
    const credito = tc ? {
      estado: tc.estado,
      limite: Number(tc.limite),
      saldo_usado: Number(tc.saldo_usado),
      pago_minimo: Math.round(Number(tc.saldo_usado) * 0.05 * 100) / 100,
      fecha_limite_pago: tc.fecha_limite_pago,
    } : null;

    return {
      cliente: { nombre: u.nombre, numero_cliente: u.numero_cliente, clabe: u.clabe },
      periodo: { desde: data.desde, hasta: data.hasta },
      saldo_inicial: saldoInicial,
      saldo_final: saldoFinal,
      total_abonos: totalAbonos,
      total_cargos: totalCargos,
      rows: finalRows,
      credito,
    };
  });

