// Server-only: enviar DMs Discord y registrarlos en notification_log.
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { sendDM, type DiscordEmbed } from "./discord.server";

export type TipoNotificacion =
  | "transaccion"
  | "recordatorio_pago_7"
  | "recordatorio_pago_1"
  | "cuenta_congelada"
  | "cuenta_descongelada"
  | "cuenta_cerrada"
  | "credito_aprobado"
  | "credito_rechazado";

export async function notify(opts: {
  usuario_id: string;
  tipo: TipoNotificacion;
  titulo: string;
  descripcion: string;
  color?: number;
  fields?: { name: string; value: string; inline?: boolean }[];
}) {
  const { data: user } = await supabaseAdmin
    .from("usuarios").select("discord_id, nombre").eq("id", opts.usuario_id).single();
  if (!user?.discord_id) return;

  const embed: DiscordEmbed = {
    title: opts.titulo,
    description: opts.descripcion,
    color: opts.color ?? 0x1e40af,
    fields: opts.fields,
    footer: { text: "Banco De México" },
    timestamp: new Date().toISOString(),
  };

  const mensaje = `${opts.titulo}\n${opts.descripcion}`;
  let estado: "enviado" | "fallido" = "enviado";
  let error: string | null = null;
  try {
    await sendDM(user.discord_id, embed);
  } catch (e) {
    estado = "fallido";
    error = (e as Error).message.slice(0, 500);
  }
  await supabaseAdmin.from("notification_log").insert({
    usuario_id: opts.usuario_id,
    discord_user_id: user.discord_id,
    tipo_notificacion: opts.tipo,
    mensaje,
    estado,
    error,
  });
}

export function formatMoney(n: number): string {
  return new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN" }).format(n);
}
