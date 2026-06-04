#!/usr/bin/env node
// Generates Bronze-layer CSV seed files from the demo data in data.js
// Run: node generate_seeds.js
// Output: ./csv/ directory with one CSV per entity

const fs   = require("fs");
const path = require("path");
const vm   = require("vm");

// Load data.js into an isolated VM context so const/let declarations
// are accessible as properties on the context object (eval() in strict
// Node modules only exposes var, not const/let).
const dataPath = path.resolve(__dirname, "../../pe-dashboard/data.js");
const src = fs.readFileSync(dataPath, "utf8")
  // strip helper functions — not needed for CSV generation
  .replace(/^function \w[\s\S]*?^}/gm, "")
  // const/let are block-scoped and never exposed on the VM context object;
  // replacing with var makes them land on ctx as expected
  .replace(/\bconst\b/g, "var")
  .replace(/\blet\b/g, "var");

const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);

const { FUND, COMPANIES, QUARTERLY_CASHFLOWS, FUND_HISTORY,
        PIPELINE, SECTOR_BREAKDOWN, GEO_BREAKDOWN } = ctx;

const OUT = path.join(__dirname, "csv");
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT);

function writeCsv(filename, rows) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const lines = [
    headers.join(","),
    ...rows.map(r =>
      headers.map(h => {
        const v = r[h];
        if (v === null || v === undefined) return "";
        const s = String(v);
        return s.includes(",") || s.includes('"') || s.includes("\n")
          ? `"${s.replace(/"/g, '""')}"` : s;
      }).join(",")
    ),
  ];
  fs.writeFileSync(path.join(OUT, filename), lines.join("\n") + "\n");
  console.log(`✅  ${filename} — ${rows.length} rows`);
}

// ── 1. fund_metrics.csv ───────────────────────────────────────────
writeCsv("fund_metrics.csv", [{
  fund_name:          FUND.name,
  short_name:         FUND.shortName,
  vintage:            FUND.vintage,
  strategy:           FUND.strategy,
  geography:          FUND.geography,
  committed_capital:  FUND.committedCapital,
  called_capital:     FUND.calledCapital,
  uncalled_capital:   FUND.uncalledCapital,
  distributions:      FUND.distributions,
  nav:                FUND.nav,
  total_value:        FUND.totalValue,
  tvpi:               FUND.tvpi,
  dpi:                FUND.dpi,
  rvpi:               FUND.rvpi,
  net_irr:            FUND.irr,
  gross_irr:          FUND.grossIrr,
  moic:               FUND.moic,
  management_fee_pct: FUND.managementFee,
  carry_pct:          FUND.carry,
  hurdle_rate_pct:    FUND.hurdleRate,
  num_portcos:        FUND.numPortcos,
  as_of_date:         FUND.asOf,
}]);

// ── 2. portfolio_companies.csv ────────────────────────────────────
writeCsv("portfolio_companies.csv", COMPANIES.map(c => ({
  id:                c.id,
  name:              c.name,
  sector:            c.sector,
  subsector:         c.subsector,
  geography:         c.geography,
  entry_year:        c.entryYear,
  entry_ev:          c.entryEV,
  entry_ebitda:      c.entryEBITDA,
  entry_multiple:    c.entryMultiple,
  invested_capital:  c.invested,
  ownership_pct:     c.ownership,
  current_ev:        c.currentEV,
  current_ebitda:    c.currentEBITDA,
  current_multiple:  c.currentMultiple,
  fmv:               c.fmv,
  moic:              c.moic,
  irr:               c.irr,
  status:            c.status,
  debt:              c.debt,
  employees:         c.employees,
  description:       c.description,
  realized:          c.realized || 0,
})));

// ── 3. company_revenue.csv  ───────────────────────────────────────
// Unpivot revenue {year: value} into rows
const revenueRows = [];
COMPANIES.forEach(c => {
  Object.entries(c.revenue).forEach(([year, revenue]) => {
    revenueRows.push({
      company_id:   c.id,
      company_name: c.name,
      year:         year.replace("E", ""),
      is_estimate:  String(year).includes("E") ? 1 : 0,
      revenue_m:    revenue,
    });
  });
});
writeCsv("company_revenue.csv", revenueRows);

// ── 4. company_ebitda.csv ─────────────────────────────────────────
const ebitdaRows = [];
COMPANIES.forEach(c => {
  Object.entries(c.ebitda).forEach(([year, ebitda]) => {
    ebitdaRows.push({
      company_id:   c.id,
      company_name: c.name,
      year:         year.replace("E", ""),
      is_estimate:  String(year).includes("E") ? 1 : 0,
      ebitda_m:     ebitda,
    });
  });
});
writeCsv("company_ebitda.csv", ebitdaRows);

// ── 5. quarterly_cashflows.csv ────────────────────────────────────
writeCsv("quarterly_cashflows.csv", QUARTERLY_CASHFLOWS.map((r, i) => ({
  row_num:            i + 1,
  quarter:            r.q,
  contributions_m:    r.contributions,
  distributions_m:    r.distributions,
  net_cashflow_m:     r.contributions + r.distributions,
})));

// ── 6. fund_history.csv ───────────────────────────────────────────
writeCsv("fund_history.csv", FUND_HISTORY.map(r => ({
  quarter: r.q,
  nav_m:   r.nav,
  net_irr: r.irr,
  tvpi:    r.tvpi,
})));

// ── 7. deal_pipeline.csv ─────────────────────────────────────────
writeCsv("deal_pipeline.csv", PIPELINE.map((d, i) => ({
  id:           i + 1,
  name:         d.name,
  sector:       d.sector,
  subsector:    d.subsector,
  source:       d.source,
  stage:        d.stage,
  target_ev_m:  d.targetEV,
  equity_m:     d.equity,
  ev_ebitda:    d.evEbitda,
  probability:  d.probability,
  owner:        d.owner,
  description:  d.description,
  notes:        d.notes,
})));

// ── 8. sector_breakdown.csv ───────────────────────────────────────
writeCsv("sector_breakdown.csv", SECTOR_BREAKDOWN.map(s => ({
  sector:      s.sector,
  fmv_m:       s.fmv,
  company_count: s.count,
  portfolio_pct: s.pct,
})));

// ── 9. geo_breakdown.csv ─────────────────────────────────────────
writeCsv("geo_breakdown.csv", GEO_BREAKDOWN.map(g => ({
  region:        g.region,
  fmv_m:         g.fmv,
  company_count: g.count,
})));

console.log(`\n📁  CSV files written to: ${OUT}`);
console.log("Next step: run  bash upload_seeds.sh <DATA_LAKE_BUCKET_NAME>");
