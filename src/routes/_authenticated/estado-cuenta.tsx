import { createFileRoute, redirect, Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { getEstadoCuenta, type EstadoCuentaResult } from "@/lib/movimientos.functions";
import { formatMXN } from "@/lib/format";

export const Route = createFileRoute("/_authenticated/estado-cuenta")({
  beforeLoad: async () => {
    if (typeof window === "undefined") return;
    const { data } = await supabase.auth.getSession();
    if (!data.session) throw redirect({ to: "/login" });
  },
  component: EstadoCuentaPage,
});

function isoDay(d: Date) { return d.toISOString().slice(0, 10); }

function EstadoCuentaPage() {
  const fn = useServerFn(getEstadoCuenta);
  const today = new Date();
  const first = new Date(today.getFullYear(), today.getMonth(), 1);
  const [desde, setDesde] = useState(isoDay(first));
  const [hasta, setHasta] = useState(isoDay(today));
  const [filtro, setFiltro] = useState<"todos" | "entradas" | "salidas">("todos");

  const { data, isLoading } = useQuery({
    queryKey: ["estado-cuenta", desde, hasta, filtro],
    queryFn: () => fn({ data: { desde: `${desde}T00:00:00.000Z`, hasta: `${hasta}T23:59:59.999Z`, filtro } }),
  });

  const descargarPDF = async () => {
    if (!data) return;
    const [{ default: jsPDF }, autoTableMod] = await Promise.all([
      import("jspdf"),
      import("jspdf-autotable"),
    ]);
    const autoTable = (autoTableMod as unknown as { default: (doc: unknown, opts: unknown) => void }).default;
    const doc = new jsPDF();
    doc.setFontSize(18); doc.text("Banco De México", 14, 18);
    doc.setFontSize(10); doc.setTextColor(100);
    doc.text("Estado de cuenta", 14, 25);
    doc.setTextColor(0); doc.setFontSize(10);
    doc.text(`Cliente: ${data.cliente.nombre}`, 14, 35);
    doc.text(`No. Cliente: ${data.cliente.numero_cliente}`, 14, 40);
    if (data.cliente.clabe) doc.text(`CLABE: ${data.cliente.clabe}`, 14, 45);
    doc.text(`Periodo: ${desde} a ${hasta}`, 14, 50);
    doc.text(`Saldo inicial: ${formatMXN(data.saldo_inicial)}`, 14, 55);
    doc.text(`Saldo final: ${formatMXN(data.saldo_final)}`, 14, 60);

    autoTable(doc, {
      startY: 68,
      head: [["Fecha", "Descripción", "Tipo", "Monto", "Saldo"]],
      body: data.rows.map((r) => [
        new Date(r.fecha).toLocaleString("es-MX"),
        r.descripcion,
        r.signo === "abono" ? "Abono" : "Cargo",
        (r.signo === "abono" ? "+" : "-") + formatMXN(r.monto),
        formatMXN(r.saldo_despues),
      ]),
      styles: { fontSize: 8 },
      headStyles: { fillColor: [15, 23, 42] },
    });

    if (data.credito) {
      const finalY = (doc as unknown as { lastAutoTable?: { finalY: number } }).lastAutoTable?.finalY ?? 80;
      doc.setFontSize(11); doc.text("Tarjeta de crédito", 14, finalY + 10);
      doc.setFontSize(9);
      doc.text(`Estado: ${data.credito.estado}`, 14, finalY + 17);
      doc.text(`Límite: ${formatMXN(data.credito.limite)}`, 14, finalY + 22);
      doc.text(`Saldo usado: ${formatMXN(data.credito.saldo_usado)}`, 14, finalY + 27);
      doc.text(`Pago mínimo (5%): ${formatMXN(data.credito.pago_minimo)}`, 14, finalY + 32);
      doc.text(`Total a pagar: ${formatMXN(data.credito.saldo_usado)}`, 14, finalY + 37);
      if (data.credito.fecha_limite_pago)
        doc.text(`Fecha límite: ${new Date(data.credito.fecha_limite_pago).toLocaleDateString("es-MX")}`, 14, finalY + 42);
    }

    doc.save(`estado-cuenta-${desde}-${hasta}.pdf`);
  };

  return (
    <div className="min-h-screen pb-16">
      <header className="container-app pt-6 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Estado de cuenta</h1>
          <p className="text-sm text-muted-foreground">Resumen del periodo</p>
        </div>
        <Link to="/home" className="text-xs text-muted-foreground underline">Salir</Link>
      </header>

      <section className="container-app mt-5 grid grid-cols-2 gap-2">
        <label className="text-xs text-muted-foreground">Desde
          <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)}
            className="mt-1 w-full rounded-lg bg-surface border border-border px-2 py-2 text-sm" />
        </label>
        <label className="text-xs text-muted-foreground">Hasta
          <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)}
            className="mt-1 w-full rounded-lg bg-surface border border-border px-2 py-2 text-sm" />
        </label>
        <select value={filtro} onChange={(e) => setFiltro(e.target.value as typeof filtro)}
          className="col-span-2 rounded-lg bg-surface border border-border px-2 py-2 text-sm">
          <option value="todos">Todos los movimientos</option>
          <option value="entradas">Solo abonos</option>
          <option value="salidas">Solo cargos</option>
        </select>
        <button onClick={descargarPDF} disabled={!data}
          className="col-span-2 bmx-tap rounded-xl bg-primary text-primary-foreground py-3 text-sm font-semibold disabled:opacity-50">
          Descargar PDF
        </button>
      </section>

      {data && (
        <section className="container-app mt-5 grid grid-cols-2 gap-2 text-xs">
          <Stat label="Saldo inicial" value={formatMXN(data.saldo_inicial)} />
          <Stat label="Saldo final" value={formatMXN(data.saldo_final)} />
          <Stat label="Total abonos" value={formatMXN(data.total_abonos)} />
          <Stat label="Total cargos" value={formatMXN(data.total_cargos)} />
        </section>
      )}

      <section className="container-app mt-5">
        {isLoading && <div className="text-sm text-muted-foreground text-center py-8">Cargando…</div>}
        {data && (
          <div className="rounded-2xl border border-border bg-surface divide-y divide-border">
            {!data.rows.length && <div className="p-5 text-sm text-muted-foreground text-center">Sin movimientos</div>}
            {data.rows.map((r) => (
              <div key={r.id} className="p-3 flex justify-between gap-2">
                <div className="min-w-0">
                  <div className="text-sm truncate">{r.descripcion}</div>
                  <div className="text-[10px] text-muted-foreground">
                    {new Date(r.fecha).toLocaleString("es-MX")} · {r.signo}
                  </div>
                </div>
                <div className="text-right shrink-0">
                  <div className={`text-sm font-mono ${r.signo === "abono" ? "text-green-500" : "text-destructive"}`}>
                    {r.signo === "abono" ? "+" : "-"}{formatMXN(r.monto)}
                  </div>
                  <div className="text-[10px] text-muted-foreground font-mono">{formatMXN(r.saldo_despues)}</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-border bg-surface p-3">
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground">{label}</div>
      <div className="text-sm font-mono font-semibold mt-1">{value}</div>
    </div>
  );
}
