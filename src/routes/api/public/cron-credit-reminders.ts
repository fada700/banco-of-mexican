import { createFileRoute } from "@tanstack/react-router";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { notify, formatMoney } from "@/lib/notifications.server";

// Cron endpoint: enviar recordatorios de pago y marcar morosidad.
// Llamado por pg_cron diariamente. Auth: header `apikey` con anon key.
export const Route = createFileRoute("/api/public/cron-credit-reminders")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const apikey = request.headers.get("apikey");
        const expected = process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_ANON_KEY;
        if (!expected || apikey !== expected) {
          return new Response("Unauthorized", { status: 401 });
        }

        const now = new Date();
        const { data: cards } = await supabaseAdmin
          .from("tarjetas_credito")
          .select("usuario_id, saldo_usado, fecha_limite_pago, dias_vencidos, estado")
          .gt("saldo_usado", 0)
          .not("fecha_limite_pago", "is", null);

        let r7 = 0, r1 = 0, vencidos = 0;
        for (const c of cards ?? []) {
          if (!c.fecha_limite_pago) continue;
          const limite = new Date(c.fecha_limite_pago);
          const diffDays = Math.floor((limite.getTime() - now.getTime()) / 86400000);
          if (diffDays === 7) {
            await notify({
              usuario_id: c.usuario_id, tipo: "recordatorio_pago_7",
              titulo: "📅 Recordatorio de pago",
              descripcion: `Tu pago de ${formatMoney(Number(c.saldo_usado))} vence en 7 días.`,
              color: 0xf59e0b,
            });
            r7++;
          } else if (diffDays === 1) {
            await notify({
              usuario_id: c.usuario_id, tipo: "recordatorio_pago_1",
              titulo: "⚠️ Pago mañana",
              descripcion: `Tu pago de ${formatMoney(Number(c.saldo_usado))} vence MAÑANA. Evita recargos.`,
              color: 0xea580c,
            });
            r1++;
          } else if (diffDays < 0) {
            const dias = Math.abs(diffDays);
            await supabaseAdmin.from("tarjetas_credito")
              .update({ dias_vencidos: dias, estado: dias >= 7 ? "bloqueada" : c.estado })
              .eq("usuario_id", c.usuario_id);
            vencidos++;
          }
        }

        return Response.json({ ok: true, recordatorios_7: r7, recordatorios_1: r1, vencidos });
      },
    },
  },
});
