import fs from "node:fs/promises";

const base = process.env.N8N_URL;           // e.g. https://your.n8n.cloud/api/v1
const key  = process.env.N8N_API_KEY;       // Personal API Key
const out  = "n8n/workflows";

const req = (p, init={}) =>
  fetch(`${base}${p}`, { ...init, headers: { "X-N8N-API-KEY": key, "Content-Type": "application/json" } });

const main = async () => {
  await fs.mkdir(out, { recursive: true });
  
  // Try to get workflows filtered by PHAM RAG tag
  const taggedUrl = "/workflows?tags=PHAM RAG";
  let r = await req(taggedUrl);
  
  if (!r.ok) {
    console.log("Tag filter failed, fetching all workflows and filtering client-side");
    r = await req("/workflows");
    if (!r.ok) throw new Error(await r.text());
    const { data: allData } = await r.json();
    // Filter workflows that have "PHAM RAG" tag
    const data = allData.filter(w => w.tags && w.tags.includes("PHAM RAG"));
    console.log(`Found ${data.length} workflows with 'PHAM RAG' tag out of ${allData.length} total workflows`);
    
    for (const w of data) {
      const wr = await req(`/workflows/${w.id}`); if (!wr.ok) throw new Error(await wr.text());
      const full = await wr.json();
      const file = `${out}/${w.id}_${w.name.replace(/\W+/g,"-").toLowerCase()}.json`;
      await fs.writeFile(file, JSON.stringify(full, null, 2));
      console.log("exported", file);
    }
  } else {
    const { data } = await r.json();
    console.log(`Found ${data.length} workflows with 'PHAM RAG' tag via API filter`);
    
    for (const w of data) {
      const wr = await req(`/workflows/${w.id}`); if (!wr.ok) throw new Error(await wr.text());
      const full = await wr.json();
      const file = `${out}/${w.id}_${w.name.replace(/\W+/g,"-").toLowerCase()}.json`;
      await fs.writeFile(file, JSON.stringify(full, null, 2));
      console.log("exported", file);
    }
  }
};
main().catch(e => { console.error(e); process.exit(1); });