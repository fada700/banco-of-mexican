import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { fetchUserRoles } from "./discord.server";
import { DISCORD_GUILD_ID, ROLE_ID_ADMIN, ROLE_ID_TRABAJADOR } from "./discord-config";

// Cache corto por discord_id para no pegarle a Discord en cada request
const roleSyncCache = new Map<string, number>();
const ROLE_SYNC_TTL_MS = 30_000;

async function resyncDiscordRoles(usuarioId: string, discordId: string): Promise<string[]> {
  const last = roleSyncCache.get(discordId) ?? 0;
  const now = Date.now();
  if (now - last >= ROLE_SYNC_TTL_MS) {
    try {
      const discordRoles = await fetchUserRoles(discordId, DISCORD_GUILD_ID);
      const isAdmin = discordRoles.includes(ROLE_ID_ADMIN);
      const isTrabajador = discordRoles.includes(ROLE_ID_TRABAJADOR);

      await supabaseAdmin
        .from("roles_usuario")
        .delete()
        .eq("usuario_id", usuarioId)
        .in("role", ["admin", "trabajador"]);

      const toInsert: { usuario_id: string; role: "admin" | "trabajador" }[] = [];
      if (isAdmin) toInsert.push({ usuario_id: usuarioId, role: "admin" });
      if (isTrabajador) toInsert.push({ usuario_id: usuarioId, role: "trabajador" });
      if (toInsert.length) {
        await supabaseAdmin
          .from("roles_usuario")
          .upsert(toInsert, { onConflict: "usuario_id,role" });
      }
      roleSyncCache.set(discordId, now);
    } catch (e) {
      console.error("[resyncDiscordRoles] fallo, uso cache DB:", e);
    }
  }
  const { data } = await supabaseAdmin
    .from("roles_usuario")
    .select("role")
    .eq("usuario_id", usuarioId);
  return (data ?? []).map((r) => r.role);
}

export interface UserData {
  id: string;
  discord_id: string;
  nombre: string;
  numero_cliente: string;
  saldo_cartera: number;
  saldo_banco: number;
  membresia: "basica" | "gold" | "zafiro" | "esmeralda" | "diamond" | "ruby" | "ruby_plus";
  estado_cuenta: "activa" | "congelada" | "cerrada";
  discord_avatar_url: string | null;
  roles: string[];
  tarjeta_debito: {
    numero: string;
    cvv: string;
    vencimiento: string;
    congelada: boolean;
  } | null;
  ultimos_movimientos: Array<{
    id: string;
    tipo: string;
    monto: number;
    descripcion: string;
    fecha: string;
  }>;
}

export const getMe = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<UserData> => {
    const authUserId = context.userId;

    const { data: usuario, error } = await supabaseAdmin
      .from("usuarios")
      .select("*")
      .eq("auth_user_id", authUserId)
      .single();
    if (error || !usuario) throw new Error("Usuario no encontrado");

    const roles = await resyncDiscordRoles(usuario.id, usuario.discord_id);

    const { data: tarjeta } = await supabaseAdmin
      .from("tarjetas_debito")
      .select("numero, cvv, vencimiento, congelada")
      .eq("usuario_id", usuario.id)
      .maybeSingle();

    const { data: movs } = await supabaseAdmin
      .from("movimientos")
      .select("id, tipo, monto, descripcion, fecha")
      .eq("usuario_id", usuario.id)
      .order("fecha", { ascending: false })
      .limit(5);

    return {
      id: usuario.id,
      discord_id: usuario.discord_id,
      nombre: usuario.nombre,
      numero_cliente: usuario.numero_cliente,
      saldo_cartera: Number(usuario.saldo_cartera),
      saldo_banco: Number(usuario.saldo_banco),
      membresia: usuario.membresia,
      estado_cuenta: (usuario as any).estado_cuenta ?? "activa",
      discord_avatar_url: usuario.discord_avatar_url,
      roles,
      tarjeta_debito: tarjeta
        ? {
            numero: tarjeta.numero,
            cvv: tarjeta.cvv,
            vencimiento: tarjeta.vencimiento,
            congelada: tarjeta.congelada,
          }
        : null,
      ultimos_movimientos: (movs ?? []).map((m) => ({
        id: m.id,
        tipo: m.tipo,
        monto: Number(m.monto),
        descripcion: m.descripcion,
        fecha: m.fecha,
      })),
    };
  });
