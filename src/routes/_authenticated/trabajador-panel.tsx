import { createFileRoute, redirect, Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import { useIsPwa } from "@/hooks/use-is-pwa";
import { getMe } from "@/lib/usuario.functions";
import {
  listarSolicitudes, aprobarSolicitud, rechazarSolicitud,
  listarDeudores, ajustarLimite, condonarDeuda,
  buscarUsuarios, congelarCuenta, descongelarCuenta, cerrarCuenta, reabrirCuenta,
  abrirDebitoManual, abrirCreditoManual,
} from "@/lib/staff.functions";
import { formatMXN } from "@/lib/format";

export const Route = createFileRoute("/_authenticated/trabajador-panel")({
  beforeLoad: async () => {
    if (typeof window === "undefined") return;
    const { data } = await supabase.auth.getSession();
    if (!data.session) throw redirect({ to: "/trabajador-login" });
  },
  component: TrabajadorPanelPage,
});

function TrabajadorPanelPage() {
  const isPwa = useIsPwa();
  const qc = useQueryClient();
  const fetchMe = useServerFn(getMe);
  const fnList = useServerFn(listarSolicitudes);
  const fnApr = useServerFn(aprobarSolicitud);
  const fnRej = useServerFn(rechazarSolicitud);
  const fnDeudores = useServerFn(listarDeudores);
  const fnLimite = useServerFn(ajustarLimite);
  const fnCondonar = useServerFn(condonarDeuda);
  const fnBuscar = useServerFn(buscarUsuarios);
  const fnCongelar = useServerFn(congelarCuenta);
  const fnDescongelar = useServerFn(descongelarCuenta);
  const fnCerrar = useServerFn(cerrarCuenta);
  const fnReabrir = useServerFn(reabrirCuenta);
  const fnAbrirDebito = useServerFn(abrirDebitoManual);
  const fnAbrirCredito = useServerFn(abrirCreditoManual);

  const { data: me, isLoading: meLoading } = useQuery({
    queryKey: ["me"], queryFn: () => fetchMe(), staleTime: 60_000,
  });
  const isStaff = !!me && (me.roles.includes("admin") || me.roles.includes("trabajador"));

  const { data: sols } = useQuery({
    queryKey: ["sols"], queryFn: () => fnList(),
    enabled: isStaff && isPwa === false, staleTime: 30_000,
  });
  const { data: deudores } = useQuery({
    queryKey: ["deudores"], queryFn: () => fnDeudores(),
    enabled: isStaff && isPwa === false, staleTime: 30_000,
  });

  const [q, setQ] = useState("");
  const { data: clientes } = useQuery({
    queryKey: ["clientes", q], queryFn: () => fnBuscar({ data: { q } }),
    enabled: isStaff && isPwa === false, staleTime: 15_000,
  });

  const [busy, setBusy] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  const [motivoCuenta, setMotivoCuenta] = useState("");
  const [limiteNuevo, setLimiteNuevo] = useState("");
  const [editLimite, setEditLimite] = useState<Record<string, string>>({});

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    if (busy) return; setBusy(true);
    try {
      await fn(); toast.success(ok);
      qc.invalidateQueries({ queryKey: ["sols"] });
      qc.invalidateQueries({ queryKey: ["deudores"] });
      qc.invalidateQueries({ queryKey: ["clientes"] });
    } catch (e) { toast.error((e as Error).message); }
    finally { setBusy(false); }
  };

  if (isPwa === null || meLoading) {
    return <div className="min-h-screen flex items-center justify-center text-muted-foreground bmx-pulse">Cargando…</div>;
  }
  if (isPwa) return <PwaBlocked path="/trabajador-panel" />;
  if (!isStaff) return <NoAccess />;

  return (
    <div className="min-h-screen pb-12">
      <header className="container-app pt-6 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Panel trabajador</h1>
          <p className="text-sm text-muted-foreground">Clientes, solicitudes y deudores</p>
        </div>
        <div className="flex items-center gap-3">
          {me?.roles.includes("admin") && (
            <Link to="/admin" className="text-xs text-muted-foreground underline">Admin</Link>
          )}
          <Link to="/home" className="text-xs text-muted-foreground underline">Salir</Link>
        </div>
      </header>

      {/* CLIENTES */}
      <section className="container-app mt-6">
        <h2 className="text-base font-semibold mb-3">Clientes</h2>
        <input value={q} onChange={(e) => setQ(e.target.value)}
          placeholder="Nombre, número cliente o Discord ID"
          className="w-full rounded-xl bg-surface border border-border px-3 py-3 text-sm" />
        <div className="mt-3 rounded-2xl border border-border bg-surface divide-y divide-border">
          {!clientes?.length && <div className="p-5 text-sm text-muted-foreground text-center">Sin resultados</div>}
          {clientes?.map((u) => (
            <div key={u.id} className="p-4">
              <button onClick={() => setOpenId((id) => (id === u.id ? null : u.id))}
                className="w-full flex justify-between items-baseline text-left">
                <div>
                  <div className="text-sm font-medium">{u.nombre}</div>
                  <div className="text-xs text-muted-foreground font-mono">{u.numero_cliente} · {u.discord_id}</div>
                </div>
                <div className="text-right">
                  <div className="text-sm font-mono">{formatMXN(u.saldo_banco)}</div>
                  <div className="text-[10px] text-muted-foreground">cartera {formatMXN(u.saldo_cartera)}</div>
                </div>
              </button>
              {openId === u.id && (
                <div className="mt-3 space-y-2 border-t border-border pt-3">
                  <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Gestión de cuenta</div>
                  <input placeholder="Motivo (opcional)" value={motivoCuenta}
                    onChange={(e) => setMotivoCuenta(e.target.value)}
                    className="w-full rounded-lg bg-background border border-border px-3 py-2 text-xs" />
                  <div className="grid grid-cols-3 gap-2">
                    <button disabled={busy}
                      onClick={() => run(() => fnCongelar({ data: { usuario_id: u.id, motivo: motivoCuenta } }), "Cuenta congelada")}
                      className="bmx-tap rounded-lg border border-border px-2 py-2 text-[11px] font-medium disabled:opacity-50">Congelar</button>
                    <button disabled={busy}
                      onClick={() => run(() => fnDescongelar({ data: { usuario_id: u.id, motivo: motivoCuenta } }), "Cuenta activa")}
                      className="bmx-tap rounded-lg border border-border px-2 py-2 text-[11px] font-medium disabled:opacity-50">Descongelar</button>
                    <button disabled={busy}
                      onClick={() => run(() => fnCerrar({ data: { usuario_id: u.id, motivo: motivoCuenta } }), "Cuenta cerrada")}
                      className="bmx-tap rounded-lg border border-destructive text-destructive px-2 py-2 text-[11px] font-medium disabled:opacity-50">Cerrar</button>
                  </div>
                  <div className="grid grid-cols-2 gap-2">
                    <button disabled={busy}
                      onClick={() => run(() => fnAbrirDebito({ data: { usuario_id: u.id, motivo: motivoCuenta } }), "Débito emitido")}
                      className="bmx-tap rounded-lg border border-border px-2 py-2 text-[11px] font-medium disabled:opacity-50">Emitir débito</button>
                    <div className="flex gap-1">
                      <input type="number" placeholder="Límite" value={limiteNuevo}
                        onChange={(e) => setLimiteNuevo(e.target.value)}
                        className="w-full rounded-lg bg-background border border-border px-2 text-[11px] font-mono" />
                      <button disabled={busy || !limiteNuevo || Number(limiteNuevo) <= 0}
                        onClick={() => run(() => fnAbrirCredito({ data: { usuario_id: u.id, limite: Number(limiteNuevo), motivo: motivoCuenta } }), "Crédito emitido")}
                        className="bmx-tap rounded-lg border border-border px-2 py-2 text-[11px] font-medium disabled:opacity-50">Crédito</button>
                    </div>
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      </section>

      <section className="container-app mt-8">
        <h2 className="text-base font-semibold mb-3">Solicitudes pendientes</h2>
        <div className="rounded-2xl border border-border bg-surface divide-y divide-border">
          {!sols?.length && <div className="p-5 text-sm text-muted-foreground text-center">Sin solicitudes</div>}
          {sols?.map((s) => (
            <div key={s.id} className="p-4 flex items-center justify-between gap-3">
              <div>
                <div className="text-sm font-medium">{s.usuario_nombre}</div>
                <div className="text-xs text-muted-foreground font-mono">{s.numero_cliente} · {s.tipo}</div>
              </div>
              <div className="flex gap-2">
                <button disabled={busy} onClick={() => run(() => fnApr({ data: { id: s.id } }), "Aprobada")}
                  className="bmx-tap rounded-lg bg-primary text-primary-foreground px-3 py-1.5 text-xs font-semibold disabled:opacity-50">Aprobar</button>
                <button disabled={busy} onClick={() => run(() => fnRej({ data: { id: s.id } }), "Rechazada")}
                  className="bmx-tap rounded-lg border border-border px-3 py-1.5 text-xs font-semibold disabled:opacity-50">Rechazar</button>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className="container-app mt-8">
        <h2 className="text-base font-semibold mb-3">Deudores</h2>
        <div className="rounded-2xl border border-border bg-surface divide-y divide-border">
          {!deudores?.length && <div className="p-5 text-sm text-muted-foreground text-center">Sin deudores</div>}
          {deudores?.map((d) => (
            <div key={d.usuario_id} className="p-4 space-y-2">
              <div className="flex justify-between items-baseline">
                <div>
                  <div className="text-sm font-medium">{d.nombre}</div>
                  <div className="text-xs text-muted-foreground font-mono">{d.numero_cliente}</div>
                </div>
                <div className="text-right">
                  <div className="text-sm font-mono font-semibold">{formatMXN(d.saldo_usado)}</div>
                  <div className="text-[10px] text-muted-foreground">de {formatMXN(d.limite)} · {d.estado}</div>
                </div>
              </div>
              <div className="flex gap-2 items-center">
                <input type="number" placeholder={`Límite ${d.limite}`}
                  value={editLimite[d.usuario_id] ?? ""}
                  onChange={(e) => setEditLimite((m) => ({ ...m, [d.usuario_id]: e.target.value }))}
                  className="flex-1 rounded-lg bg-background border border-border px-2 py-1.5 text-xs font-mono" />
                <button disabled={!editLimite[d.usuario_id] || busy}
                  onClick={() => run(() => fnLimite({ data: { usuario_id: d.usuario_id, nuevo_limite: Number(editLimite[d.usuario_id]) } }), "Límite ajustado")}
                  className="bmx-tap rounded-lg border border-border px-3 py-1.5 text-xs font-medium disabled:opacity-50">Ajustar</button>
                <button disabled={busy} onClick={() => run(() => fnCondonar({ data: { usuario_id: d.usuario_id } }), "Deuda condonada")}
                  className="bmx-tap rounded-lg border border-destructive text-destructive px-3 py-1.5 text-xs font-medium disabled:opacity-50">Condonar</button>
              </div>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function PwaBlocked({ path }: { path: string }) {
  return (
    <div className="min-h-screen flex items-center justify-center px-6 bg-background">
      <div className="max-w-sm text-center">
        <div className="text-[10px] uppercase tracking-[0.4em] text-destructive font-bold">Bloqueado en PWA</div>
        <h2 className="text-2xl font-bold mt-3">Abre el panel desde el navegador</h2>
        <p className="text-sm text-muted-foreground mt-3">
          Por seguridad, los paneles de staff no funcionan dentro de la app instalada.
        </p>
        <div className="mt-5 rounded-xl bg-surface border border-border p-3 font-mono text-xs break-all">
          banco-play.lovable.app{path}
        </div>
        <p className="text-xs text-muted-foreground mt-4">
          Cópialo en Safari, Chrome o cualquier navegador del móvil o PC.
        </p>
      </div>
    </div>
  );
}

function NoAccess() {
  const logout = async () => {
    await supabase.auth.signOut();
    window.location.replace("/");
  };
  return (
    <div className="min-h-screen flex items-center justify-center px-6 bg-background">
      <div className="max-w-sm text-center">
        <div className="text-[10px] uppercase tracking-[0.4em] text-destructive font-bold">Sin permisos</div>
        <h2 className="text-2xl font-bold mt-3">No tienes acceso</h2>
        <p className="text-sm text-muted-foreground mt-3">
          Tu cuenta no tiene el rol necesario para entrar a este panel.
        </p>
        <div className="mt-6 flex flex-col gap-2">
          <button onClick={logout} className="bmx-tap rounded-xl bg-primary text-primary-foreground py-3 text-sm font-semibold">
            Cerrar sesión
          </button>
          <Link to="/home" className="bmx-tap rounded-xl border border-border py-3 text-sm font-medium">
            Volver al inicio
          </Link>
        </div>
      </div>
    </div>
  );
}

export { PwaBlocked, NoAccess };
