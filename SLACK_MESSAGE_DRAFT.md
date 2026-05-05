# Slack Message Draft — Integration Skills Platform

---

Neata! Asa cum am discutat cu Adrian, vreau sa pun pe hartie propunerea legata de integrari in Sferal si cum as vedea eu implementarea din punct de vedere tehnic.

**Context rapid:** Cele mai frecvente cereri de la useri sunt integrarile cu servicii romanesti — ANAF SPV (e-Factura, e-Transport), SmartBill, Oblio, API-uri bancare (BT, BCR, ING), curieri (FAN, Sameday), plati (Netopia) etc. In demo-ul cu cei 70 de cursanti, am aratat live o integrare completa cu e-Factura. Am pregatit in prealabil un ghid detaliat de implementare adaptat pe stack-ul nostru (TS, Node, Prisma), cu tot ce trebuie: arhitectura, cod complet, pitfall-uri si fix-uri. L-am dat ca prompt, si in 2 mesaje integrarea era gata. Toata lumea a ramas surprinsa, mai ales ca niciunul nu avea background tehnic.

Ideea mea e sa transformam asta intr-un avantaj sistematic, nu un one-off. Concret:

---

**1. Skills curate per integrare**

Pentru fiecare serviciu, cream un skill (ghid detaliat de implementare) pe care instanta de Claude Code din spatele produsului il incarca automat cand userul cere integrarea respectiva. Ghiduri curate, testate pe implementari reale, cu:
- Arhitectura si flow-ul complet
- Exemple de TypeScript inline, adaptat pe stack-ul nostru
- Pitfall-uri documentate cu fix-uri (astea fac diferenta — sunt lucrurile pe care Claude nu le stie nativ)
- Config, env variables, Prisma schemas, Zod validation

Skills-urile pot fi oricat de lungi — la ~1000-3000 linii per skill, suntem confortabili in context window-ul de 200K. Nu e o problema pentru ca userul lucreaza pe o singura integrare la un moment dat, iar conversatiile sunt scurte (1-3 mesaje).

**2. Doua nivele de skills**

*Integration skills* — cum sa comunici cu un serviciu:
- `anaf-efactura-crud` — list, download, parse, store facturi UBL/CII
- `smartbill-crud` — sync facturi, estimari, chitante
- `bt-bank-statements` — extrase cont via PSD2
- `fan-courier-crud` — generare AWB, tracking, print etichete
- etc.

*Workflow skills* — logica de business care combina mai multe integrari:
- `invoice-bank-matching` — match facturi ANAF cu tranzactii bancare, tracking plati
- `auto-reconciliation` — reconciliere facturi emise cu incasari
- `delivery-tracking-dashboard` — tracking unificat multi-curier
- `e-transport-from-orders` — generare declaratii e-Transport din comenzi

Skills-urile sunt compozabile. Userul zice "vreau sa vad ce facturi am primit si care sunt platite din banca" → se incarca skill-ul de e-factura + bank statements + matching → Claude construieste tot.

Aici e cel mai mare selling point — nimeni de pe piata (Lovable, Bolt, Base44) nu are cunostinte specifice de API-uri romanesti.

**3. Mentenanta — Change Detection Pipeline**

API-urile se schimba. ANAF in special e imprevizibil. Ca sa nu ramanem desincronizati, propun un pipeline automat pe doua layere:

*Layer 1 — Doc diffing:* Scraping periodic pe paginile de documentatie ale fiecarui serviciu. Cand se schimba ceva (endpoint nou, parametru modificat, deprecare), detectam automat. Se poate folosi changedetection.io (self-hosted, open source) sau un scraper custom.

*Layer 2 — Canary tests (contract testing):* Pentru fiecare integrare mentinem un set de teste care ruleaza periodic (la 6h) contra API-urilor reale. Testele valideaza contractul comportamental pe care skill-ul se bazeaza (formatul raspunsurilor, structura XML-urilor, flow-ul de auth etc.). Cand un test pica, stim ca ceva s-a schimbat upstream — chiar daca documentatia nu reflecta asta inca.

Cand pipeline-ul detecteaza o schimbare:
1. Clasifica tipul (breaking change, endpoint nou, deprecare, etc.)
2. Claude (via SDK) genereaza un draft de update pentru skill-ul afectat
3. Se deschide un PR automat in repo-ul de skills
4. Un dev face review si merge

Deci nu auto-update orbeste — always human in the loop pe review.

**4. Change Intelligence + Newsletter**

Bonus: pe langa update-ul skill-urilor, fiecare schimbare detectata genereaza un "brief" — ce s-a schimbat, ce capabilitati noi exista, ce impact are pentru userii nostri. Daca schimbarea e relevanta din punct de vedere de produs, brief-ul e rescris automat pentru audienta non-tehnica si pus intr-un queue de review. Practic:

SmartBill adauga un endpoint de bulk export → pipeline-ul detecteaza → skill updatat → brief generat → newsletter draft: "Acum poti adauga un sync complet al istoricului de facturi in dashboard-ul tau".

Userul vede capabilitati noi aparand fara sa stie ca in spate s-a schimbat un API. Noi nu am scris cod — pipeline-ul a facut totul, noi doar am dat review.

---

**Pasi concret de executie:**

1. **Saptamanile 1-3:** Cream primele 5 skills pentru cele mai cerute integrari + 1-2 workflow skills. Validam cu useri reali.
2. **Saptamanile 3-5:** Punem la punct reference apps + contract tests (canary tests pe CI).
3. **Saptamanile 5-7:** Adaugam doc monitoring (scraping + diffing).
4. **Saptamanile 7-10:** Pipeline-ul complet de triage automat + change intelligence + newsletter drafts.

---

**Intrebari pentru discutie:**

- Cum functioneaza exact incarcarea skill-urilor in instantele de Claude Code? Trebuie sa modificam ceva in produs ca sa suporte compozitia (mai multe skills incarcate simultan)?
- Cum se propaga un skill updatat la instantele userilor? Instant din repo sau necesita deploy?
- Avem conturi de test / sandbox pentru serviciile target (ANAF, SmartBill, banci)?
- Userii ar trebui sa vada un catalog de integrari disponibile, sau sa fie invizibil (Claude pur si simplu stie)?

Am un doc tehnic complet cu toata arhitectura detaliata (diagrame, cod, structura repo-urilor, contract test examples etc.). Il pot share-ui oricand daca vreti sa intrati in detalii.