# ANAF SPV API — Comprehensive Documentation

> **Last updated:** February 2026
> **Sources:** Official ANAF PDFs, mfinante.gov.ro, static.anaf.ro, community open-source implementations, ANAF's official Java client (MfpAnaf/ClientSPV)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Authentication](#2-authentication)
3. [Headless / Server Deployment](#3-headless--server-deployment)
4. [e-Factura API](#4-e-factura-api)
5. [e-Transport API](#5-e-transport-api)
6. [SPV Web Services](#6-spv-web-services)
7. [Company Lookup API (PlatitorTvaRest v9)](#7-company-lookup-api-platitortvarest-v9)
8. [Rate Limits](#8-rate-limits)
9. [UBL Invoice Format (CIUS-RO)](#9-ubl-invoice-format-cius-ro)
10. [Test / Sandbox Environment](#10-test--sandbox-environment)
11. [Error Reference](#11-error-reference)
12. [Official Documentation Links](#12-official-documentation-links)
13. [Community SDKs & Libraries](#13-community-sdks--libraries)
12. [Community SDKs & Libraries](#12-community-sdks--libraries)

---

## 1. Overview

**ANAF** (Agentia Nationala de Administrare Fiscala) is Romania's National Agency for Fiscal Administration. **SPV** (Spatiul Privat Virtual — Virtual Private Space) is ANAF's secure digital platform that provides taxpayers with electronic access to fiscal services.

### API Families

ANAF exposes four major API families:

| API Family | Purpose | Auth Required | Primary Domain |
|---|---|---|---|
| **e-Factura (FCTEL)** | Electronic invoicing (B2B, B2C, B2G) | OAuth2 or Certificate | `api.anaf.ro` / `webserviceapl.anaf.ro` |
| **e-Transport (ETRANSPORT)** | Goods transport declarations | OAuth2 or Certificate | `api.anaf.ro` / `webserviceapl.anaf.ro` |
| **SPV Web Services (SPVWS2)** | Tax declarations, fiscal data, obligations | TLS Client Certificate | `webserviced.anaf.ro` |
| **Company Lookup (PlatitorTvaRest)** | VAT payer status, company data | None (public) | `webservicesp.anaf.ro` |

### Regulatory Context

| Date | Regulation |
|---|---|
| **January 1, 2024** | B2B e-invoicing mandatory for all domestic transactions in Romania |
| **January 1, 2026** | All B2B, B2C, and B2G invoices must be transmitted through RO e-Factura. B2B/B2C invoices due within 5 working days of the tax point |
| **Ongoing** | e-TVA pre-filled VAT return system live for all VAT-registered taxpayers |
| **Ongoing** | e-Transport UIT codes required for monitored goods transportation |

---

## 2. Authentication

ANAF uses three authentication mechanisms depending on the API:

### 2.1 OAuth 2.0 Authorization Code Flow

Used by: **e-Factura**, **e-Transport** (via `api.anaf.ro`)

ANAF implements a standard OAuth 2.0 Authorization Code flow. The critical distinction: the authorization endpoint requires the user to authenticate with a **qualified digital certificate** (USB token / smart card).

#### OAuth 2.0 Endpoints

| Endpoint | URL |
|---|---|
| Authorization | `https://logincert.anaf.ro/anaf-oauth2/v1/authorize` |
| Token | `https://logincert.anaf.ro/anaf-oauth2/v1/token` |
| Revoke | `https://logincert.anaf.ro/anaf-oauth2/v1/revoke` |

#### Step 1: Register Your Application

1. Navigate to `https://www.anaf.ro` → Servicii Online → Inregistrare utilizatori → Dezvoltatori aplicatii → Inregistrare pentru API-uri
2. Click "Continua" and complete registration (activation email sent)
3. After account creation, log in at `anaf.ro` with credentials
4. Click "Editare profil OAuth" → "Generare Client ID"
5. You receive: **client_id**, **client_secret**
6. Configure your **redirect_uri** (must be a functional website)

Official procedure: [Oauth_procedura_inregistrare_aplicatii_portal_ANAF.pdf](https://static.anaf.ro/static/10/Anaf/Informatii_R/API/Oauth_procedura_inregistrare_aplicatii_portal_ANAF.pdf)

#### Step 2: Get Authorization Code

The user must have a qualified digital certificate installed in their browser. **Firefox is NOT supported** by ANAF's authentication portal.

```bash
# Redirect the user's browser to:
https://logincert.anaf.ro/anaf-oauth2/v1/authorize?\
  response_type=code&\
  client_id={client_id}&\
  redirect_uri={redirect_uri}&\
  token_content_type=jwt
```

After the user authenticates with their certificate, ANAF redirects to your `redirect_uri` with `?code={authorization_code}`.

#### Step 3: Exchange Code for Tokens

```bash
curl -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "code={authorization_code}" \
  -d "client_id={client_id}" \
  -d "client_secret={client_secret}" \
  -d "redirect_uri={redirect_uri}" \
  -d "token_content_type=jwt"
```

**Response:**
```json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "token_type": "Bearer",
  "expires_in": 7776000
}
```

#### Token Lifetimes

| Token | Validity | Notes |
|---|---|---|
| Access Token | **90 days** (7,776,000 seconds) | JWT signed with RS512 |
| Refresh Token | **365 days** | After expiry, full re-enrollment required |

#### JWT Structure

**Header:** `{"alg": "RS512", "kid": "anaf_2023_2024"}`

**Claims:**
```json
{
  "token_type": "Bearer",
  "scope": "clientappid issuer role serial",
  "iss": "https://logincert.anaf.ro",
  "iat": 1706875254,
  "exp": 1714651254,
  "clientappid": "{your_client_id}",
  "roles": "HELLO@EFACTURA@ETRANSPORT@SRV_EFACTURA",
  "serial": "{certificate_serial}"
}
```

#### Available Scopes/Roles

| Role | Description |
|---|---|
| `HELLO` | Test/validation endpoint |
| `EFACTURA` | Electronic invoice operations |
| `ETRANSPORT` | e-Transport declarations |
| `SRV_EFACTURA` | e-Factura service access |

#### Step 4: Refresh Token

No digital certificate required — only the refresh token and client credentials.

```bash
curl -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "refresh_token={refresh_token}" \
  -d "client_id={client_id}" \
  -d "client_secret={client_secret}"
```

When the refresh token expires (after 365 days), ANAF returns `"Refresh Token status is expired"` and the full certificate-based authorization flow must be repeated.

#### Using the Access Token

All protected API calls require:
```
Authorization: Bearer {access_token}
```

### 2.2 TLS Client Certificate

Used by: **SPV Web Services** (`webserviced.anaf.ro`)

Authentication is performed directly at the TLS level by presenting a qualified digital certificate. No OAuth flow needed.

### 2.3 No Authentication

Used by: **Company Lookup API**, **XML Validation**, **XML-to-PDF Conversion** (all via `webservicesp.anaf.ro`)

These are public endpoints requiring no authentication.

---

## 3. Headless / Server Deployment

Running ANAF API integrations on a headless VM (no browser, no USB token attached) requires specific strategies for each auth mechanism.

### Architecture Overview

```
MANUAL (once/year)                      HEADLESS VM (automated 24/7)
┌──────────────────────────┐            ┌──────────────────────────────────┐
│ Machine with browser     │            │                                  │
│ + USB certificate token  │            │  ┌─ e-Factura/e-Transport ─────┐ │
│                          │            │  │ Bearer token from           │ │
│ 1. Visit logincert.anaf  │──tokens──→│  │ oauth_tokens.json           │ │
│    .ro/anaf-oauth2       │            │  │ Auto-refresh every 90 days  │ │
│ 2. Authorize with cert   │            │  └─────────────────────────────┘ │
│ 3. Get auth code         │            │                                  │
│ 4. Exchange for tokens   │            │  ┌─ SPV Web Services ──────────┐ │
│ 5. Push tokens to VM     │            │  │ TLS client certificate      │ │
│                          │            │  │ from /etc/anaf/cert.p12     │ │
│ Repeat when refresh      │            │  │ Used on every request       │ │
│ token expires (365 days) │            │  └─────────────────────────────┘ │
└──────────────────────────┘            │                                  │
                                        │  ┌─ Company Lookup ────────────┐ │
                                        │  │ No auth needed              │ │
                                        │  │ Works out of the box        │ │
                                        │  └─────────────────────────────┘ │
                                        └──────────────────────────────────┘
```

### 3.1 OAuth2 (e-Factura, e-Transport) on a Headless VM

Only the **initial authorization** requires a browser + certificate. After that, the VM operates autonomously with tokens.

**What you need on the VM:**
- `client_id` and `client_secret` (from ANAF app registration)
- `access_token` (valid 90 days, auto-refreshable)
- `refresh_token` (valid 365 days, requires manual renewal)

**Initial token acquisition (manual, on a machine with browser + USB token):**

Build a small helper page (can be `localhost:8080`) that:
1. Redirects to ANAF's authorization URL
2. Receives the callback with the authorization code
3. Exchanges the code for tokens
4. Stores/pushes the tokens to your VM

```bash
# Step 1: User visits this URL in a browser with the USB certificate installed
# https://logincert.anaf.ro/anaf-oauth2/v1/authorize?\
#   response_type=code&client_id={client_id}&redirect_uri=http://localhost:8080/callback&token_content_type=jwt

# Step 2: Your callback page receives ?code=AUTH_CODE and exchanges it:
curl -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -d "grant_type=authorization_code" \
  -d "code={AUTH_CODE}" \
  -d "client_id={client_id}" \
  -d "client_secret={client_secret}" \
  -d "redirect_uri=http://localhost:8080/callback" \
  -d "token_content_type=jwt"

# Step 3: Save the tokens to a file and push to VM
# → {"access_token":"eyJ...","refresh_token":"eyJ...","expires_in":7776000}
```

**Automated token refresh (runs on the VM, no browser/certificate needed):**

```bash
curl -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "refresh_token={stored_refresh_token}" \
  -d "client_id={client_id}" \
  -d "client_secret={client_secret}"
```

**Token lifecycle management:**

| Event | Action | Who/Where |
|---|---|---|
| Every API call | Use `access_token` in `Authorization: Bearer` header | VM (automated) |
| Access token nearing expiry (~90 days) | Refresh using `refresh_token` → new `access_token` + new `refresh_token` | VM (automated) |
| Refresh token expired (365 days) | Full OAuth2 flow with browser + USB certificate | Human (manual, once/year) |
| Refresh fails with `"Refresh Token status is expired"` | Alert operator → manual renewal needed | VM alerts, human acts |

**Recommended: refresh proactively.** Don't wait for expiry. Refresh the access token weekly or monthly to keep both tokens fresh. Each refresh gives you a new refresh token too, resetting its 365-day clock.

### 3.2 TLS Client Certificate (SPV Web Services) on a Headless VM

Every SPV request needs a client certificate at the TLS level. The key question: **what form is your certificate in?**

#### Option A: Software certificate (.p12 / .pfx) — Recommended

If you get a **file-based** qualified digital certificate, deploy it directly to the VM:

```bash
# Place certificate on VM with strict permissions
chmod 600 /etc/anaf/certificate.p12

# Use it for all SPV requests
curl --cert-type P12 --cert /etc/anaf/certificate.p12:password \
  "https://webserviced.anaf.ro/SPVWS2/rest/listaMesaje?zile=1&cif=12345678"

# Or convert to PEM first for libraries that prefer PEM:
openssl pkcs12 -in certificate.p12 -out client-cert.pem -clcerts -nokeys
openssl pkcs12 -in certificate.p12 -out client-key.pem -nocerts -nodes
chmod 600 client-key.pem

curl --cert /etc/anaf/client-cert.pem --key /etc/anaf/client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/listaMesaje?zile=1&cif=12345678"
```

**Where to get a software certificate in Romania:**

| Provider | Website | Notes |
|---|---|---|
| **certSIGN** | https://certsign.ro | Romania's main qualified trust service provider. Ask for "certificat digital calificat pe suport software". |
| **DigiSign** | https://digisign.ro | Both hardware and software certificate options. |
| **Trans Sped** | https://transsped.ro | Another qualified certificate provider. |

**Cost:** ~100–300 RON/year depending on provider and certificate type.

#### Option B: USB hardware token — Workarounds

If you already have a USB token (eToken, smart card) and the private key is non-exportable:

| Approach | How | Complexity |
|---|---|---|
| **USB/IP passthrough** | Plug USB token into a physical machine near the VM, forward via USB/IP or hypervisor USB passthrough | Medium |
| **PKCS#11 middleware** | Use OpenSC or vendor middleware to access the token programmatically; requires token physically connected | Medium |
| **Get a software certificate** | Order a separate .p12 from certSIGN/DigiSign for server use | **Simplest** |

**Recommendation:** Don't try to make a USB token work on a headless VM. Get a software certificate (~200 RON/year) and save yourself the complexity.

#### Option C: Cloud-based qualified certificates

Newer providers offer remote/cloud-based qualified certificates where signing happens via an API:

| Provider | Service |
|---|---|
| certSIGN | Remote qualified signing service |
| DigiSign | Cloud-based qualified signatures |

These are designed for server-to-server use cases but require a separate API integration with the certificate provider.

### 3.3 Recommended File Layout on the VM

```
/etc/anaf/
├── certificate.p12            # SPV Web Services TLS cert (chmod 600, root-only)
├── client-cert.pem            # PEM version of the cert (for libraries)
├── client-key.pem             # PEM private key (chmod 600, root-only)
├── oauth_tokens.json          # e-Factura/e-Transport tokens (chmod 600)
└── client_credentials.json    # client_id + client_secret (chmod 600)
```

**`oauth_tokens.json` example:**
```json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "token_type": "Bearer",
  "expires_in": 7776000,
  "obtained_at": "2025-01-15T10:00:00Z",
  "expires_at": "2025-04-15T10:00:00Z",
  "refresh_expires_at": "2026-01-15T10:00:00Z"
}
```

**`client_credentials.json` example:**
```json
{
  "client_id": "your_registered_client_id",
  "client_secret": "your_registered_client_secret",
  "redirect_uri": "http://localhost:8080/callback"
}
```

### 3.4 Application Startup Checklist

Your application should perform these checks on startup:

```
1. Load /etc/anaf/oauth_tokens.json
   ├─ access_token expired?  → auto-refresh using refresh_token
   ├─ refresh_token expired? → ALERT: manual renewal needed (once/year)
   └─ both valid?            → proceed

2. Load /etc/anaf/certificate.p12
   ├─ certificate expired?   → ALERT: renew with certSIGN/DigiSign
   └─ valid?                 → proceed

3. Test connectivity:
   ├─ e-Factura:  GET /stareMesaj?id_incarcare=1  (expect error, confirms auth works)
   ├─ SPV:        GET /listaMesaje?zile=1          (confirms cert works)
   └─ Public:     POST /PlatitorTvaRest/v9/tva     (confirms network)
```

### 3.5 Shopping List

| Item | Where | Cost | Renewal |
|---|---|---|---|
| ANAF API app registration (client_id/secret) | anaf.ro portal — free | Free | One-time |
| Software certificate (.p12) for SPV | certSIGN.ro or DigiSign.ro | ~100–300 RON/year | Annual |
| USB token (for annual OAuth2 renewal only) | You probably already have one | ~100–200 RON | Every 1–3 years |
| A machine with a browser (for annual OAuth2 renewal) | Your laptop/desktop | — | — |

---

## 4. e-Factura API

The e-Factura system supports upload, validation, status checking, download, and conversion of electronic invoices in UBL 2.1 format conforming to CIUS-RO.

### Base URLs

| Environment | OAuth2 (`api.anaf.ro`) | Certificate (`webserviceapl.anaf.ro`) |
|---|---|---|
| **Production** | `https://api.anaf.ro/prod/FCTEL/rest` | `https://webserviceapl.anaf.ro/prod/FCTEL/rest` |
| **Test** | `https://api.anaf.ro/test/FCTEL/rest` | `https://webserviceapl.anaf.ro/test/FCTEL/rest` |

Public endpoints (validation, conversion) use: `https://webservicesp.anaf.ro/prod/FCTEL/rest`

### Complete Endpoint Reference

| # | Service | Method | Path | Auth |
|---|---------|--------|------|------|
| 1a | Upload B2B | POST | `/upload?standard={s}&cif={c}` | OAuth2 / Cert |
| 1b | Upload B2C | POST | `/uploadb2c?standard={s}&cif={c}` | OAuth2 / Cert |
| 2 | Message Status | GET | `/stareMesaj?id_incarcare={id}` | OAuth2 / Cert |
| 3a | List Messages | GET | `/listaMesajeFactura?zile={z}&cif={c}` | OAuth2 / Cert |
| 3b | List Messages (paginated) | GET | `/listaMesajePaginatieFactura?startTime={t1}&endTime={t2}&cif={c}&pagina={p}` | OAuth2 / Cert |
| 4 | Download | GET | `/descarcare?id={id}` | OAuth2 / Cert |
| 5 | Validate XML | POST | `/validare/{standard}` | None |
| 6 | XML to PDF | POST | `/transformare/{standard}/{novld}` | None |
| 7 | Validate Signature | POST | `/api/validate/signature` | None |

---

### 4.1 Upload B2B Invoice

```
POST /upload?standard={standard}&cif={cif}[&extern=DA][&autofactura=DA][&executare=DA]
```

**Required Parameters:**

| Parameter | Type | Values | Description |
|---|---|---|---|
| `standard` | String | `UBL`, `CN`, `CII`, `RASP` | Invoice format standard |
| `cif` | Numeric | — | CUI for error message routing. Must have SPV rights. |

**Optional Parameters:**

| Parameter | Value | When to use |
|---|---|---|
| `extern` | `DA` | Buyer is outside Romania (no CUI or NIF) |
| `autofactura` | `DA` | Self-billing: beneficiary issues invoice on behalf of supplier |
| `executare` | `DA` | Invoice filed by enforcement body on behalf of debtor |

**Standard Values:**

| Value | Meaning |
|---|---|
| `UBL` | UBL 2.1 Invoice (CIUS-RO) |
| `CN` | Credit Note (UBL Credit Note schema) |
| `CII` | Cross Industry Invoice (UN/CEFACT CII D16B) |
| `RASP` | Buyer response message to invoice issuer |

**Request:**
- Body: Raw XML content
- Header: `Content-Type: text/plain`
- **Max body size: 5 MB**

```bash
curl -X POST \
  "https://api.anaf.ro/prod/FCTEL/rest/upload?standard=UBL&cif=12345678" \
  -H "Authorization: Bearer {access_token}" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml
```

**Success Response (XML):**
```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<header xmlns="mfp:anaf:dgti:spv:respUploadFisier:v1"
        dateResponse="202401132008"
        ExecutionStatus="0"
        index_incarcare="5006096656"/>
```

- `ExecutionStatus="0"` → Success
- `ExecutionStatus="1"` → Error
- `index_incarcare` → Upload tracking index (use with `/stareMesaj`)

### 4.2 Upload B2C Invoice

```
POST /uploadb2c?standard={standard}&cif={cif}[&extern=DA][&autofactura=DA][&executare=DA]
```

Same parameters and behavior as Upload B2B, but for B2C invoices.

```bash
curl -X POST \
  "https://api.anaf.ro/prod/FCTEL/rest/uploadb2c?standard=UBL&cif=12345678" \
  -H "Authorization: Bearer {access_token}" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice_b2c.xml
```

### 4.3 Message Status (Stare Mesaj)

```
GET /stareMesaj?id_incarcare={upload_index}
```

| Parameter | Type | Description |
|---|---|---|
| `id_incarcare` | Numeric | Upload index from the upload response |

```bash
curl "https://api.anaf.ro/prod/FCTEL/rest/stareMesaj?id_incarcare=5006096656" \
  -H "Authorization: Bearer {access_token}"
```

**Response (XML):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<header xmlns="mfp:anaf:dgti:efactura:stareMesajFactura:v1"
        stare="ok"
        id_descarcare="3008662942"/>
```

**Status Values (`stare`):**

| Value | Meaning | Next Action |
|---|---|---|
| `ok` | Validated and processed successfully | Use `id_descarcare` to download signed invoice. Invoice is available to buyer. |
| `nok` | Errors found, file NOT processed | Download contains identified errors + MF signature. Invoice does NOT reach buyer. |
| `XML cu erori nepreluat de sistem` | File rejected during upload | Error returned as response to the upload request itself. |
| `in prelucrare` | Processing not yet complete | Poll again later. |

### 4.4 List Messages (Simple)

```
GET /listaMesajeFactura?zile={days}&cif={cif}[&filtru={filter}]
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `zile` | Numeric | Yes | Number of days to look back (1–60) |
| `cif` | Numeric | Yes | Tax identification number (CUI) |
| `filtru` | String | No | Filter by message type |

**Filter Values:**

| Value | Meaning |
|---|---|
| *(none)* | All messages |
| `T` | FACTURA TRIMISA — Sent invoices |
| `P` | FACTURA PRIMITA — Received invoices |
| `E` | ERORI FACTURA — Invoice errors |
| `R` | MESAJ CUMPARATOR — Buyer messages (received/sent) |

```bash
curl "https://api.anaf.ro/prod/FCTEL/rest/listaMesajeFactura?zile=30&cif=12345678&filtru=P" \
  -H "Authorization: Bearer {access_token}"
```

**Response (JSON):**
```json
{
  "mesaje": [
    {
      "data_creare": "202401132004",
      "cif": "12345678",
      "id_solicitare": "5006096454",
      "detalii": "Factura cu id_incarcare=5006096454 renderizata ANAF",
      "tip": "FACTURA PRIMITA",
      "id": "3008615564",
      "cif_emitent": "87654321",
      "cif_beneficiar": "12345678"
    }
  ],
  "serial": "1234ABCD",
  "cui": "12345678",
  "titlu": "Lista Mesaje factura primite in ultimele 30 zile"
}
```

**Response Fields per Message:**

| Field | Description |
|---|---|
| `data_creare` | Creation date (YYYYMMDDHHmm) |
| `cif` | CIF of the querying entity |
| `id_solicitare` | Upload index (same as `index_incarcare` from upload) |
| `detalii` | Human-readable description |
| `tip` | Message type: FACTURA TRIMISA / FACTURA PRIMITA / ERORI FACTURA / MESAJ CUMPARATOR |
| `id` | Download ID (use with `/descarcare`) |
| `cif_emitent` | Seller CIF |
| `cif_beneficiar` | Buyer CIF |

### 4.5 List Messages (Paginated)

```
GET /listaMesajePaginatieFactura?startTime={ts1}&endTime={ts2}&cif={cif}&pagina={page}[&filtru={filter}]
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `startTime` | Numeric | Yes | Unix timestamp in **milliseconds** |
| `endTime` | Numeric | Yes | Unix timestamp in **milliseconds** |
| `cif` | Numeric | Yes | Tax identification number (CUI) |
| `pagina` | Numeric | Yes | Page number (500 messages per page) |
| `filtru` | String | No | Same filter values as simple list |

```bash
# Example: messages from Jan 1 to Jan 31, 2024, page 1
curl "https://api.anaf.ro/prod/FCTEL/rest/listaMesajePaginatieFactura?\
startTime=1704067200000&endTime=1706745600000&cif=12345678&pagina=1" \
  -H "Authorization: Bearer {access_token}"
```

### 4.6 Download (Descarcare)

```
GET /descarcare?id={download_id}
```

| Parameter | Type | Description |
|---|---|---|
| `id` | Numeric | Download ID from the message list response (`id` field) or status response (`id_descarcare`) |

```bash
curl "https://api.anaf.ro/prod/FCTEL/rest/descarcare?id=3008662942" \
  -H "Authorization: Bearer {access_token}" \
  -o invoice.zip
```

**Response:** ZIP file containing two XML files:
1. The original invoice XML (or error details if status was `nok`)
2. The Ministry of Finance electronic signature XML

### 4.7 Validate XML

```
POST /validare/{standard}
```

| Parameter | Type | Values | Description |
|---|---|---|---|
| `standard` | String (path) | `FACT1`, `FCN` | `FACT1` for invoices, `FCN` for credit notes |

**No authentication required.** This is a public endpoint on `webservicesp.anaf.ro`.

```bash
curl -X POST \
  "https://webservicesp.anaf.ro/prod/FCTEL/rest/validare/FACT1" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml
```

### 4.8 XML to PDF (Transformare)

```
POST /transformare/{standard}/{novld}
```

| Parameter | Type | Values | Description |
|---|---|---|---|
| `standard` | String (path) | `FACT1`, `FCN` | `FACT1` for invoices, `FCN` for credit notes |
| `novld` | String (path) | `DA` or omit | If `DA`, XML is NOT validated before transformation. PDF correctness is not guaranteed for unvalidated XMLs. |

```bash
# With validation:
curl -X POST \
  "https://webservicesp.anaf.ro/prod/FCTEL/rest/transformare/FACT1" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml \
  -o invoice.pdf

# Without validation:
curl -X POST \
  "https://webservicesp.anaf.ro/prod/FCTEL/rest/transformare/FACT1/DA" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml \
  -o invoice.pdf
```

### 4.9 Validate Signature

```
POST /api/validate/signature
```

**Multipart form data** — both files are found in the ZIP from the download service.

| Parameter | Type | Description |
|---|---|---|
| `file` | MultipartFile | The invoice XML file |
| `signature` | MultipartFile | The XML file containing the MF signature |

```bash
curl -X POST \
  "https://webservicesp.anaf.ro/api/validate/signature" \
  -F "file=@invoice.xml" \
  -F "signature=@signature.xml"
```

---

## 5. e-Transport API

The e-Transport system monitors the movement of goods within Romania and for international transactions. A **UIT (Unique Identification Transport)** code is generated for each valid declaration.

### Applicability Thresholds

**Domestic transport** (high-fiscal-risk goods):
- Weight exceeding **500 kg**, OR
- Value exceeding **10,000 RON**

**International transport** (intra-EU and non-EU): all goods require declaration regardless of value/weight.

**UIT validity:** 5 days (standard) or 15 days (intra-community).

### Base URLs

| Environment | OAuth2 | Certificate |
|---|---|---|
| **Production** | `https://api.anaf.ro/prod/ETRANSPORT/ws` | `https://webserviceapl.anaf.ro/prod/ETRANSPORT/ws` |
| **Test** | `https://api.anaf.ro/test/ETRANSPORT/ws` | `https://webserviceapl.anaf.ro/test/ETRANSPORT/ws` |

### Endpoints

| Method | Path | Description |
|---|---|---|
| POST | `/upload/{standard}/{cif}/2` | Upload V2 transport declaration |
| GET | `/lista/{zile}/{cif}` | List declarations |
| GET | `/stareMesaj/{id}` | Get declaration status |

### Upload Declaration

```bash
curl -X POST \
  "https://api.anaf.ro/prod/ETRANSPORT/ws/upload/UBL/12345678/2" \
  -H "Authorization: Bearer {access_token}" \
  -H "Content-Type: application/xml" \
  --data-binary @transport_declaration.xml
```

### Operation Type Codes (codTipOperatiune)

| Code | Description | Declarant |
|---|---|---|
| **10** | Intra-community acquisition | Buyer |
| **12** | Inward processing / Lohn operations (EU) — entry | Buyer |
| **14** | Call-off stock — inwards | Buyer |
| **20** | Intra-community delivery | Supplier |
| **22** | Outward processing / Lohn operations (EU) — exit | Supplier |
| **24** | Call-off stock — outwards | Supplier |
| **30** | Domestic transport | Supplier |
| **40** | Import | Buyer |
| **50** | Export | Supplier |
| **60** | Transaction within EU — Entrance of goods for storage/new shipment | Buyer |
| **70** | Transaction within EU — Exit of goods after storage/new shipment | Supplier |

### Scope Operation Codes (codScopOperatiune)

| Code | Description |
|---|---|
| 101 | Merchandise (Comercializare) |
| 201 | Production (Productie) |
| 301 | Free products (Gratuitati) |
| 401 | Commercial equipment (Echipament comercial) |
| 501 | Fixed assets (Mijloace fixe) |
| 601 | Own consumption (Consum propriu) |
| 703 | Delivery including installation |
| 704 | Intercompany transfer (Transfer intre gestiuni) |
| 705 | Goods provided to customer |
| 801 | Financial/operational lease |
| 802 | Goods under warranty |
| 901 | Exempt operations |
| 1001 | Ongoing investment |
| 1101 | Donations/aid |
| 9901 | Other |
| 9999 | Same as the operation |

### Required Data Fields

#### Transported Goods (`bunuriTransportate` array)

| Field | Type | Required | Description |
|---|---|---|---|
| `codTarifar` | String | Yes | CN tariff code (min 4 digits) |
| `denumireMarfa` | String | Yes | Commercial name (max 200 chars) |
| `codScopOperatiune` | Number | Yes | Purpose code (see table above) |
| `cantitate` | Number | Yes | Quantity (> 0) |
| `codUnitateMasura` | String | Yes | UN/ECE unit of measure code |
| `greutateNeta` | Number | Conditional | Net weight (required except types 60, 70) |
| `greutateBruta` | Number | Yes | Gross weight (> 0, must be >= net weight) |
| `valoareLeiFaraTva` | Number | Conditional | Value in RON excl. VAT (required except types 60, 70) |

#### Commercial Partner (`partenerComercial`)

| Field | Type | Description |
|---|---|---|
| `codTara` | String | ISO 3166-1 country code |
| `cod` | String | Identifier (PNC, UIC, FIN, or "PF" for individuals) |
| `denumire` | String | Partner name (max 200 chars) |

#### Transport Details (`dateTransport`)

| Field | Type | Required | Description |
|---|---|---|---|
| `nrVehicul` | String | Yes | Vehicle plate number |
| `nrRemorca1` | String | No | First trailer plate number |
| `nrRemorca2` | String | No | Second trailer plate number |
| `codTaraTransportator` | String | Yes | Transporter country (ISO) |
| `codTransportator` | String | Yes | Transporter ID |
| `denumireTransportator` | String | Yes | Transporter name (max 200 chars) |
| `dataTransport` | String | Yes | Shipment date (YYYY-MM-DD) |
| `codPtf` | String | Conditional | Border crossing point code |
| `codBirouVamal` | String | Conditional | Customs office code |

#### Locations (`locIncarcare` / `locDescarcare`)

| Field | Type | Description |
|---|---|---|
| `codJudet` | String | County code (AB, AR, AG, B, BC, BH, BN, etc.) |
| `denumireLocalitate` | String | City/town (max 100 chars) |
| `denumireStrada` | String | Street name (max 100 chars) |
| `numar` | String | Street number |
| `bloc`, `scara`, `etaj`, `apartament` | String | Building details |
| `codPostal` | String | Postal code |

#### Transport Documents (`documenteTransport` array)

| tipDocument Code | Meaning |
|---|---|
| 10 | CMR waybill |
| 20 | Invoice (Factura) |
| 30 | Delivery note (Aviz de insotire a marfii) |
| 9999 | Other |

### Declaration Lifecycle

```
Notify (submit) ──→ UPLOADED (UIT generated)
                        │
                   (~1 minute)
                        │
                  ┌─────┴─────┐
                  ▼           ▼
             PROCESSED     REJECTED
                  │
        ┌─────────┼──────────┐
        ▼         ▼          ▼
    Modify   ModifyVehicle  Confirm ──→ CONFIRMED
        │                    │
        ▼                    ├──→ Partially confirmed (20)
    MODIFICATION             └──→ Disclaimed (30)
                  │
                  ▼
               Delete ──→ DELETED
```

**Confirmation Types (`tipConfirmare`):**

| Code | Description |
|---|---|
| 10 | Confirmed (complete delivery) |
| 20 | Partially confirmed |
| 30 | Disclaimed (rejected by receiver) |

**Shipment Status Values:**

| Status | Description |
|---|---|
| `UPLOADED` | UIT obtained, pending ANAF confirmation |
| `PROCESSED` | ANAF accepted the declaration |
| `CONFIRMED` | Delivery confirmed by receiver |
| `REJECTED` | ANAF rejected the declaration |
| `DELETED` | UIT cancelled |
| `DELETE_FAILED` | Deletion attempt failed |
| `UPLOAD_FAILED` | Upload attempt failed |
| `CONFIRMATION_FAILED` | Confirmation attempt failed |

---

## 6. SPV Web Services

SPV (Spatiul Privat Virtual) is ANAF's digital mailbox for every taxpayer. It is **much broader than e-Factura** — while e-Factura handles only invoices, SPV is where ANAF delivers (and you can request) **all** fiscal documents: tax declarations, payment obligations, fiscal situation reports, audit notifications, penalty decisions, and more.

### SPV vs e-Factura — What Goes Where

| | e-Factura API | SPV Web Services |
|---|---|---|
| **What it handles** | Only invoices (sent, received, errors, buyer messages) | Everything else: tax declarations, fiscal data, ANAF notifications, assessments, penalties |
| **Domain** | `api.anaf.ro` / `webserviceapl.anaf.ro` | `webserviced.anaf.ro` |
| **Auth** | OAuth2 Bearer token (easy to automate) | TLS client certificate (harder to automate) |
| **Data flow** | Bidirectional (upload + download invoices) | Bidirectional (request documents + receive ANAF messages) |

### Authentication

SPV Web Services use **TLS client certificate authentication** — no OAuth2 flow. Your qualified digital certificate (`.pem` or `.p12`) is presented at the TLS handshake level.

```bash
# All SPV requests use --cert and --key instead of Authorization header
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/..."
```

If your certificate is in PKCS#12 format:
```bash
curl --cert-type P12 --cert client.p12:password \
  "https://webserviced.anaf.ro/SPVWS2/rest/..."
```

### Base URL

```
https://webserviced.anaf.ro/SPVWS2/rest
```

### Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/listaMesaje?zile={days}&cif={cif}` | List all messages in your SPV mailbox (1–60 days) |
| GET | `/descarcare?id={message_id}` | Download a specific message/document (PDF) |
| POST | `/cerere` | Request a specific document from ANAF |

---

### 6.1 List Messages (SPV Mailbox)

This returns **all messages** in your virtual private space — not just invoices, but tax declaration confirmations, ANAF notifications, audit notices, penalty decisions, payment obligation notices, and any document ANAF has placed in your mailbox.

```
GET /listaMesaje?zile={days}&cif={cif}
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `zile` | Numeric | Yes | Number of days to look back (1–60) |
| `cif` | Numeric | No | Filter by specific CUI (useful if your certificate covers multiple entities) |

```bash
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/listaMesaje?zile=30&cif=12345678"
```

**Response (JSON):**
```json
{
  "titlu": "Lista mesaje din ultimele 30 zile",
  "mesaje": [
    {
      "data_creare": "202401150800",
      "id": "12345",
      "tip": "D300",
      "detalii": "Declaratia 300 pentru luna 12/2024 - confirmare depunere"
    },
    {
      "data_creare": "202401140900",
      "id": "12346",
      "tip": "Obligatii de plata",
      "detalii": "Nota de obligatii de plata - ianuarie 2024"
    },
    {
      "data_creare": "202401100700",
      "id": "12347",
      "tip": "Notificare",
      "detalii": "Notificare privind depunerea declaratiei D112"
    }
  ],
  "id_solicitare": "req-abc-123",
  "eroare": null
}
```

**What you'll find in your mailbox:**
- Confirmation receipts for submitted declarations
- Payment obligation notices
- ANAF notifications and reminders
- Audit / inspection notices
- Penalty decisions
- Responses to previous `/cerere` requests
- Any document ANAF decides to communicate to you

---

### 6.2 Download Message

Downloads a specific document from your SPV mailbox. Response is typically a **PDF** file.

```
GET /descarcare?id={message_id}
```

| Parameter | Type | Description |
|---|---|---|
| `id` | Numeric | Message ID from the `/listaMesaje` response |

```bash
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/descarcare?id=12345" \
  -o document.pdf
```

---

### 6.3 Submit Request (Cerere)

Proactively request a specific document from ANAF. The document is generated and placed in your SPV mailbox, where you can then download it via `/listaMesaje` + `/descarcare`.

```
POST /cerere
```

```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "D300", "cui": "12345678", "an": "2024", "luna": "12"}'
```

**Request Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `tip` | String | Yes | Document type (see comprehensive table below) |
| `cui` | String | Yes | Tax identification number (CUI) |
| `an` | String | Conditional | Year (required for periodic declarations) |
| `luna` | String | Conditional | Month (required for monthly declarations) |
| `motiv` | String | Conditional | Reason for request |
| `numar_inregistrare` | String | Conditional | Registration number (for specific document lookup) |
| `cui_pui` | String | Conditional | CUI of subsidiary/branch |

**Response (JSON):**
```json
{
  "titlu": "Cerere inregistrata",
  "id_solicitare": "tracking_id_456",
  "eroare": null
}
```

The response confirms the request was registered. The actual document will appear in your `/listaMesaje` within seconds to minutes.

**Typical workflow:**
```bash
# 1. Request a document
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "Obligatii de plata", "cui": "12345678"}'

# 2. Wait a few seconds, then list messages to find it
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/listaMesaje?zile=1&cif=12345678"

# 3. Download the document using the id from the list
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/descarcare?id=12350" \
  -o obligatii_de_plata.pdf
```

---

### 6.4 Supported Document Types (`tip`) — Complete Reference

#### Tax Declarations

These request copies of previously submitted tax declarations or their processing confirmations.

| Type | Description | Required Params | Typical Frequency |
|---|---|---|---|
| `D100` | Payment obligations to state budget | `cui`, `an`, `luna` | Monthly |
| `D101` | Annual income tax declaration (profit tax) | `cui`, `an` | Annual |
| `D106` | Declaration for specific income types | `cui`, `an`, `luna` | Monthly |
| `D112` | Social contributions declaration (CAS, CASS, employer contributions) | `cui`, `an`, `luna` | Monthly |
| `D120` | Excise declarations | `cui`, `an`, `luna` | Monthly |
| `D130` | Other tax declarations | `cui`, `an`, `luna` | Varies |
| `D180` | Declaration of non-resident income | `cui`, `an` | Annual |
| `D205` | Informative declaration on withholding tax | `cui`, `an` | Annual |
| `D208` | Declaration of income from abroad | `cui`, `an` | Annual |
| `D212` | Annual declaration for individuals (PFA/II/IF) | `cui`, `an` | Annual |
| `D300` | VAT return (decontul de TVA) | `cui`, `an`, `luna` | Monthly/Quarterly |
| `D301` | Special VAT return (non-residents) | `cui`, `an`, `luna` | Monthly/Quarterly |
| `D311` | Declaration for special VAT regime (small enterprises) | `cui`, `an` | Annual |
| `D390` | Recapitulative statement for intra-EU supplies | `cui`, `an`, `luna` | Monthly |
| `D394` | Informative declaration on domestic deliveries/purchases/services | `cui`, `an`, `luna` | Monthly |

#### Fiscal Situation & Company Data

These generate on-demand reports about your current fiscal status.

| Type | Description | Required Params | What You Get |
|---|---|---|---|
| `DATE IDENTIFICARE` | Company identification data | `cui` | Official company name, address, registration number, CAEN code, legal form, fiscal authority |
| `VECTOR FISCAL` | Tax vector (registrations) | `cui` | Complete list of taxes you're registered for (VAT, profit tax, microenterprise tax, etc.) with start/end dates |
| `Situatie Sintetica` | Summary fiscal situation | `cui` | Overview "health check" — taxes owed, overpayments, compliance status across all tax types |
| `Obligatii de plata` | Outstanding payment obligations | `cui` | What you currently owe to the state — broken down by tax type, principal, penalties, interest |
| `Nota obligatiilor de plata` | Detailed payment obligations note | `cui` | Detailed version of obligations — official document that can be used in legal/banking contexts |
| `Istoric bilant` | Balance sheet history | `cui` | Historical annual balance sheets as submitted to ANAF |
| `InterogariBanci` | Bank account queries | `cui` | ANAF's records of your declared bank accounts (all banks where you have accounts) |
| `Registru intrari-iesiri` | Entry-exit register | `cui` | Register of documents entering/leaving your SPV |
| `Istoric Spatiu Virtual` | SPV activity history | `cui` | Full history of all SPV interactions — documents received, requests made, downloads performed |

#### Practical Examples

**Check what taxes you owe:**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "Obligatii de plata", "cui": "12345678"}'
```

**Get your tax vector (what taxes you're registered for):**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "VECTOR FISCAL", "cui": "12345678"}'
```

**Download a copy of your last VAT return:**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "D300", "cui": "12345678", "an": "2024", "luna": "12"}'
```

**Get your company's official fiscal summary:**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "Situatie Sintetica", "cui": "12345678"}'
```

**Get your balance sheet history:**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "Istoric bilant", "cui": "12345678"}'
```

**See what bank accounts ANAF knows about:**
```bash
curl --cert client.pem --key client-key.pem \
  -X POST "https://webserviced.anaf.ro/SPVWS2/rest/cerere" \
  -H "Content-Type: application/json" \
  -d '{"tip": "InterogariBanci", "cui": "12345678"}'
```

---

### 6.5 Unsolicited ANAF Messages

Beyond documents you explicitly request, ANAF also **pushes documents into your SPV mailbox** that you should monitor. These include:

| Message Type | Description | Action Required |
|---|---|---|
| **Declaration confirmations** | Receipt confirming ANAF accepted your submitted declaration | Informational — archive for records |
| **Declaration rejections** | ANAF rejected a submitted declaration with errors | Fix errors and resubmit |
| **Payment obligation notices** | Periodic notice of amounts due | Review and pay by deadline |
| **Notification reminders** | Reminders about upcoming filing deadlines | Submit declarations on time |
| **Audit/inspection notices** | ANAF announces a tax audit or inspection | Prepare documentation; consult accountant/lawyer |
| **Penalty decisions** | Fines or penalties for non-compliance | Pay or contest within legal deadline |
| **Offset decisions** | ANAF offset an overpayment against a debt | Informational — verify amounts |
| **Enforcement notices** | ANAF initiating enforcement proceedings for unpaid debts | Urgent — pay or contest immediately |
| **Certificate of fiscal attestation** | Fiscal compliance certificate (requested or automatic) | Use for public tenders, contracts |

**Recommendation:** Poll `/listaMesaje` at least once daily to catch any new ANAF communications. Some notices have tight response deadlines.

```bash
# Daily check for new ANAF messages
curl --cert client.pem --key client-key.pem \
  "https://webserviced.anaf.ro/SPVWS2/rest/listaMesaje?zile=1&cif=12345678"
```

---

### 6.6 Response Format

All SPV Web Services endpoints return JSON:

**Success (list messages):**
```json
{
  "titlu": "Lista mesaje din ultimele 30 zile",
  "mesaje": [
    {
      "data_creare": "202401150800",
      "id": "12345",
      "tip": "D300",
      "detalii": "Declaratia 300 pentru luna 12/2024 - confirmare depunere"
    }
  ],
  "id_solicitare": "tracking_id_123",
  "eroare": null
}
```

**Success (submit request):**
```json
{
  "titlu": "Cerere inregistrata",
  "id_solicitare": "tracking_id_456",
  "eroare": null
}
```

**Error:**
```json
{
  "titlu": "Eroare",
  "mesaje": null,
  "id_solicitare": null,
  "eroare": "Nu aveti drept in SPV pentru CIF=12345678"
}
```

### 6.7 Automation Considerations

| Challenge | Details |
|---|---|
| **Certificate management** | TLS client certificates expire and must be renewed. Unlike OAuth2 tokens (90-day access, 365-day refresh), certificate renewal typically requires visiting ANAF or a certificate provider. |
| **No test environment** | Unlike e-Factura (which has `/test/` URLs), SPV Web Services do not have a documented sandbox. |
| **Document format** | Downloaded documents are typically PDFs — not machine-readable structured data. Parsing requires PDF extraction. |
| **Polling required** | There are no webhooks or push notifications. You must poll `/listaMesaje` periodically to detect new messages. |
| **Official Java client** | ANAF provides an official Java client at [github.com/MfpAnaf/ClientSPV](https://github.com/MfpAnaf/ClientSPV). Contact: `spv.webservice@mfinante.ro` |

---

## 7. Company Lookup API (PlatitorTvaRest v9)

Public API for querying company information, VAT status, and fiscal data. **No authentication required.**

### Endpoint

```
POST https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva
Content-Type: application/json
```

### Rate Limits (this endpoint)

- **Maximum 100 CUIs per request**
- **Maximum 1 request per second per client**

### Request

JSON array of objects:

```bash
curl -X POST https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva \
  -H "Content-Type: application/json" \
  -d '[
    {"cui": 12345678, "data": "2025-01-15"},
    {"cui": 87654321, "data": "2025-01-15"}
  ]'
```

| Field | Type | Description |
|---|---|---|
| `cui` | Number | Fiscal identification number (without "RO" prefix) |
| `data` | String | Query date in `YYYY-MM-DD` format |

### Response

```json
{
  "cod": 200,
  "message": "SUCCESS",
  "found": [
    {
      "date_generale": { ... },
      "inregistrare_scop_Tva": { ... },
      "inregistrare_RTVAI": { ... },
      "stare_inactiv": { ... },
      "inregistrare_SplitTVA": { ... },
      "adresa_sediu_social": { ... },
      "adresa_domiciliu_fiscal": { ... }
    }
  ],
  "notFound": []
}
```

### Response Fields — `date_generale`

| Field | Description |
|---|---|
| `cui` | Fiscal code |
| `data` | Query date |
| `denumire` | Company name |
| `adresa` | Fiscal domicile address (formatted string) |
| `nrRegCom` | Trade Registry registration number |
| `telefon` | Phone at fiscal domicile |
| `fax` | Fax at fiscal domicile |
| `codPostal` | Postal code |
| `act` | Authorization act |
| `stare_inregistrare` | Company registration status |
| `data_inregistrare` | Registration date |
| `cod_CAEN` | CAEN activity code |
| `iban` | IBAN account |
| `statusRO_e_Factura` | `true` if in RO e-Factura Registry at queried date |
| `organFiscalCompetent` | Competent fiscal authority |
| `forma_de_proprietate` | Ownership form |
| `forma_organizare` | Organization form |
| `forma_juridica` | Legal form |

### Response Fields — `inregistrare_scop_Tva`

| Field | Description |
|---|---|
| `scpTVA` | `true` = VAT payer at queried date |
| `perioade_TVA` | Array of VAT registration periods |
| `perioade_TVA[].data_inceput_ScpTVA` | VAT registration start date |
| `perioade_TVA[].data_sfarsit_ScpTVA` | VAT cancellation date |
| `perioade_TVA[].data_anul_imp_ScpTVA` | Date of cancellation operation |
| `perioade_TVA[].mesaj_ScpTVA` | Legal basis for cancellation |

### Response Fields — `inregistrare_RTVAI` (VAT-on-Collection)

| Field | Description |
|---|---|
| `dataInceputTvaInc` | Start date |
| `dataSfarsitTvaInc` | End date |
| `dataActualizareTvaInc` | Update date |
| `dataPublicareTvaInc` | Publication date |
| `tipActTvaInc` | Update type |
| `statusTvaIncasare` | `true` = applies VAT-on-collection |

### Response Fields — `stare_inactiv`

| Field | Description |
|---|---|
| `dataInactivare` | Inactivation date |
| `dataReactivare` | Reactivation date |
| `dataPublicare` | Publication date |
| `dataRadiere` | De-registration date |
| `statusInactivi` | `true` = inactive at queried date |

### Response Fields — `inregistrare_SplitTVA`

| Field | Description |
|---|---|
| `dataInceputSplitTVA` | Split VAT start date |
| `dataAnulareSplitTVA` | Split VAT cancellation date |
| `statusSplitTVA` | `true` = applies split VAT payment |

### Response Fields — `adresa_sediu_social` (Registered Office)

| Field | Description |
|---|---|
| `sdenumire_Strada` | Street name |
| `snumar_Strada` | Street number |
| `sdenumire_Localitate` | City/town |
| `scod_Localitate` | Locality code |
| `sdenumire_Judet` | County name |
| `scod_Judet` | County code |
| `scod_JudetAuto` | County auto code |
| `stara` | Country |
| `sdetalii_Adresa` | Address details |
| `scod_Postal` | Postal code |

### Response Fields — `adresa_domiciliu_fiscal` (Fiscal Domicile)

Same structure as `adresa_sediu_social` but prefixed with `d` instead of `s` (e.g. `ddenumire_Strada`, `dnumar_Strada`, etc.)

---

## 8. Rate Limits

Source: [limiteApeluriAPI.txt](https://mfinante.gov.ro/static/10/eFactura/limiteApeluriAPI.txt)

### Global Limit

**Maximum 1,000 API calls per minute** across all methods.

### Per-Endpoint Limits (e-Factura)

| Endpoint | Per-Message/Day | Per-CUI/Day |
|---|---|---|
| `/upload` (invoices) | No limit | No limit |
| `/upload` (RASP files) | — | Max 1,000/day |
| `/stareMesaj` | Max 100 per specific message | No limit on total per CUI |
| `/listaMesajeFactura` (simple) | — | Max 1,500/day |
| `/listaMesajePaginatieFactura` (paginated) | — | Max 100,000/day |
| `/descarcare` | Max 10 per specific message | No limit on total per CUI |

### Company Lookup Rate Limits

- Max **100 CUIs** per request
- Max **1 request per second** per client

### Enforcement

> **Warning:** Repeated ignoring of rate limit error messages can result in API access being blocked for that user and, in severe cases, blocking access for the entire application.

If limits are insufficient, contact ANAF via SPV contact form at `www.anaf.ro` for a limit review.

---

## 9. UBL Invoice Format (CIUS-RO)

Romanian e-invoicing uses **UBL 2.1** (Universal Business Language) conforming to the **European standard EN 16931** with the Romanian national customization **CIUS-RO**.

### Customization ID (required in every invoice)

```
urn:cen.eu:en16931:2017#compliant#urn:efactura.mfinante.ro:CIUS-RO:1.0.1
```

### XML Namespaces

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
         xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
         xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
         xmlns:ccts="urn:un:unece:uncefact:documentation:2"
         xmlns:qdt="urn:oasis:names:specification:ubl:schema:xsd:QualifiedDataTypes-2"
         xmlns:udt="urn:oasis:names:specification:ubl:schema:xsd:UnqualifiedDataTypes-2">
```

### Mandatory Invoice Elements

| Business Term | XML Element | Description | Constraints |
|---|---|---|---|
| BT-1 | `cbc:ID` | Invoice number | Max 200 characters |
| BT-2 | `cbc:IssueDate` | Issue date | `YYYY-MM-DD` |
| BT-3 | `cbc:InvoiceTypeCode` | Invoice type code | See table below |
| BT-5 | `cbc:DocumentCurrencyCode` | Currency | ISO 4217 (e.g. `RON`) |
| BT-24 | `cbc:CustomizationID` | CIUS-RO specification ID | Must be the exact CIUS-RO URN |
| BG-4 | `cac:AccountingSupplierParty` | Seller information | Name, address, CUI, reg number |
| BG-7 | `cac:AccountingCustomerParty` | Buyer information | Name, address, CUI |
| BG-22 | `cac:LegalMonetaryTotal` | Document totals | See monetary fields below |
| BG-25 | `cac:InvoiceLine` | Invoice line items | At least one line required |

### Invoice Type Codes (BT-3)

| Code | Meaning |
|---|---|
| 380 | Standard Invoice |
| 381 | Credit Note |
| 384 | Corrected Invoice |
| 389 | Self-invoice (autofactura) |
| 751 | Invoice information for accounting purposes |

### VAT Category Codes (UNCL5305)

| Code | Meaning |
|---|---|
| S | Standard rate |
| Z | Zero rated |
| E | Exempt from tax |
| AE | Reverse charge |
| G | Free export item |
| O | Services outside scope of tax |
| K | Intra-community supply |
| L | Canary Islands |
| M | Ceuta and Melilla |
| B | Transferred (VAT) |

### Monetary Total Fields (BG-22)

| Business Term | XML Element | Description |
|---|---|---|
| BT-106 | `cbc:LineExtensionAmount` | Net sum of all line amounts |
| BT-107 | `cbc:AllowanceTotalAmount` | Total discounts |
| BT-108 | `cbc:ChargeTotalAmount` | Total charges |
| BT-109 | `cbc:TaxExclusiveAmount` | Total without VAT |
| BT-112 | `cbc:TaxInclusiveAmount` | Total with VAT |
| BT-113 | `cbc:PrepaidAmount` | Advance payments |
| BT-114 | `cbc:PayableRoundingAmount` | Rounding |
| BT-115 | `cbc:PayableAmount` | Amount due for payment |

### Minimal Invoice XML Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
         xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
         xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">

  <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:efactura.mfinante.ro:CIUS-RO:1.0.1</cbc:CustomizationID>
  <cbc:ID>INV-2024-001</cbc:ID>
  <cbc:IssueDate>2024-01-15</cbc:IssueDate>
  <cbc:DueDate>2024-02-15</cbc:DueDate>
  <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
  <cbc:DocumentCurrencyCode>RON</cbc:DocumentCurrencyCode>

  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyName>
        <cbc:Name>Supplier SRL</cbc:Name>
      </cac:PartyName>
      <cac:PostalAddress>
        <cbc:StreetName>Strada Exemplu 10</cbc:StreetName>
        <cbc:CityName>Bucuresti</cbc:CityName>
        <cbc:PostalZone>010101</cbc:PostalZone>
        <cac:Country>
          <cbc:IdentificationCode>RO</cbc:IdentificationCode>
        </cac:Country>
      </cac:PostalAddress>
      <cac:PartyTaxScheme>
        <cbc:CompanyID>RO12345678</cbc:CompanyID>
        <cac:TaxScheme>
          <cbc:ID>VAT</cbc:ID>
        </cac:TaxScheme>
      </cac:PartyTaxScheme>
      <cac:PartyLegalEntity>
        <cbc:RegistrationName>Supplier SRL</cbc:RegistrationName>
        <cbc:CompanyID>J40/1234/2020</cbc:CompanyID>
      </cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingSupplierParty>

  <cac:AccountingCustomerParty>
    <cac:Party>
      <cac:PartyName>
        <cbc:Name>Buyer SRL</cbc:Name>
      </cac:PartyName>
      <cac:PostalAddress>
        <cbc:StreetName>Bulevardul Test 5</cbc:StreetName>
        <cbc:CityName>Cluj-Napoca</cbc:CityName>
        <cbc:PostalZone>400001</cbc:PostalZone>
        <cac:Country>
          <cbc:IdentificationCode>RO</cbc:IdentificationCode>
        </cac:Country>
      </cac:PostalAddress>
      <cac:PartyTaxScheme>
        <cbc:CompanyID>RO87654321</cbc:CompanyID>
        <cac:TaxScheme>
          <cbc:ID>VAT</cbc:ID>
        </cac:TaxScheme>
      </cac:PartyTaxScheme>
      <cac:PartyLegalEntity>
        <cbc:RegistrationName>Buyer SRL</cbc:RegistrationName>
        <cbc:CompanyID>J12/5678/2019</cbc:CompanyID>
      </cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingCustomerParty>

  <cac:TaxTotal>
    <cbc:TaxAmount currencyID="RON">190.00</cbc:TaxAmount>
    <cac:TaxSubtotal>
      <cbc:TaxableAmount currencyID="RON">1000.00</cbc:TaxableAmount>
      <cbc:TaxAmount currencyID="RON">190.00</cbc:TaxAmount>
      <cac:TaxCategory>
        <cbc:ID>S</cbc:ID>
        <cbc:Percent>19</cbc:Percent>
        <cac:TaxScheme>
          <cbc:ID>VAT</cbc:ID>
        </cac:TaxScheme>
      </cac:TaxCategory>
    </cac:TaxSubtotal>
  </cac:TaxTotal>

  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="RON">1000.00</cbc:LineExtensionAmount>
    <cbc:TaxExclusiveAmount currencyID="RON">1000.00</cbc:TaxExclusiveAmount>
    <cbc:TaxInclusiveAmount currencyID="RON">1190.00</cbc:TaxInclusiveAmount>
    <cbc:PayableAmount currencyID="RON">1190.00</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>

  <cac:InvoiceLine>
    <cbc:ID>1</cbc:ID>
    <cbc:InvoicedQuantity unitCode="EA">10</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="RON">1000.00</cbc:LineExtensionAmount>
    <cac:Item>
      <cbc:Name>Product Example</cbc:Name>
      <cac:ClassifiedTaxCategory>
        <cbc:ID>S</cbc:ID>
        <cbc:Percent>19</cbc:Percent>
        <cac:TaxScheme>
          <cbc:ID>VAT</cbc:ID>
        </cac:TaxScheme>
      </cac:ClassifiedTaxCategory>
    </cac:Item>
    <cac:Price>
      <cbc:PriceAmount currencyID="RON">100.00</cbc:PriceAmount>
    </cac:Price>
  </cac:InvoiceLine>

</Invoice>
```

### Validation

- **Schematron rules** (.sch files) for operational rules and VAT rules
- Based on EN16931 CEN/TC 434 model
- Validation artifacts version: **1.0.8** for RO_CIUS
- Online ANAF validator: `https://www.anaf.ro/uploadxmi/`
- Online XML-to-PDF: `https://www.anaf.ro/uploadxml`
- ANAF invoice builder: `https://www.anaf.ro/CompletareFactura/faces/factura/informatiigenerale.xhtml`

---

## 10. Test / Sandbox Environment

The test environment mirrors the production API but does not affect real tax records.

### Test URLs

Replace `/prod/` with `/test/` in all `webserviceapl.anaf.ro` and `api.anaf.ro` URLs:

| Service | Production URL | Test URL |
|---|---|---|
| e-Factura Upload (OAuth2) | `https://api.anaf.ro/prod/FCTEL/rest/upload` | `https://api.anaf.ro/test/FCTEL/rest/upload` |
| e-Factura Upload (Cert) | `https://webserviceapl.anaf.ro/prod/FCTEL/rest/upload` | `https://webserviceapl.anaf.ro/test/FCTEL/rest/upload` |
| e-Factura Status (OAuth2) | `https://api.anaf.ro/prod/FCTEL/rest/stareMesaj` | `https://api.anaf.ro/test/FCTEL/rest/stareMesaj` |
| e-Factura List (OAuth2) | `https://api.anaf.ro/prod/FCTEL/rest/listaMesajeFactura` | `https://api.anaf.ro/test/FCTEL/rest/listaMesajeFactura` |
| e-Factura Download (OAuth2) | `https://api.anaf.ro/prod/FCTEL/rest/descarcare` | `https://api.anaf.ro/test/FCTEL/rest/descarcare` |
| e-Transport Upload (OAuth2) | `https://api.anaf.ro/prod/ETRANSPORT/ws/upload` | `https://api.anaf.ro/test/ETRANSPORT/ws/upload` |

### Notes

- The same OAuth2 tokens work for both test and production environments
- Invoices uploaded to test are flagged internally and do not enter the real e-Factura system
- The test environment is recommended for all development and integration testing
- Public endpoints (validation, XML-to-PDF, company lookup) do not have separate test environments — they function the same regardless

---

## 11. Error Reference

### Upload Errors

| Condition | Error Message |
|---|---|
| Invalid XML syntax | `Fisierul transmis nu este valid. org.xml.sax.SAXParseException; lineNumber: 1; columnNumber: 1; Content is not allowed in prolog.` |
| Invalid `standard` parameter | `Valorile acceptate pentru parametrul standard sunt UBL, CII sau RASP` |
| XML body > 5 MB | `Marime fisier transmis mai mare de 5 MB.` |

### Message Status Errors

| Condition | Error Message |
|---|---|
| Invoice not found | `Eroare: nu exista factura cu id_incarcare= {id}` |
| No query rights | `Nu aveti dreptul de interogare pentru id_incarcare= {id}` |
| Invalid ID format | `Id_incarcare introdus= {val} nu este un numar intreg` |

### List Messages Errors (JSON)

| Condition | `eroare` Field |
|---|---|
| Days > 60 | `Numarul de zile introdus este mai mare de 60` |
| No SPV rights for CIF | `Nu aveti drept in SPV pentru CIF={cif}` |
| Invalid days value | `Numarul de zile introdus= {val} nu este un numar intreg` |
| Invalid CIF value | `CIF introdus= {val} nu este un numar` |

### Download Errors (JSON)

| Condition | `eroare` Field |
|---|---|
| No invoice for ID | `Pentru id={id} nu exista inregistrata nici o factura` |
| No download rights | `Nu aveti dreptul sa descarcati acesta factura` |
| Invalid ID format | `Id descarcare introdus= {val} nu este un numar intreg` |

### Certificate / Portal Errors

| Error | Cause | Resolution |
|---|---|---|
| Access denied (403) | Certificate not enrolled on MFP site | Enroll certificate via "Declaratii electronice" on ANAF site |
| User unauthorized | Token not inserted; multiple tokens; expired certificate; wrong certificate | Verify single token, valid certificate, correct selection |
| No cookie support | Browser cookies disabled | Enable cookies in browser settings |
| `ssl_error_renegotiation_not_allowed` | Firefox SSL issue | Set `security.ssl.allow_unrestricted_renego_everywhere__temporarily_available_pref` to `true` in `about:config` |
| Cryptographic device not found | USB token not detected | Verify device is inserted, no other tokens connected |
| Certificate not authorized for CUI | Certificate not registered for the CUI | Verify CUI, verify certificate enrollment, use Form 150 for representation documents |

### Rate Limit Errors

When daily limits are exceeded, ANAF returns a rate limit error. The specific HTTP status code is not formally documented but community libraries reference **HTTP 429** and a custom `LimitExceededError` pattern. Repeated violations can result in API access being **blocked for the user** or **the entire application**.

---

## 12. Official Documentation Links

### Primary Official Sources

| Resource | URL |
|---|---|
| ANAF API Registration Portal | https://www.anaf.ro/anaf/internet/ANAF/servicii_online/inreg_api |
| OAuth Registration Procedure (PDF) | https://static.anaf.ro/static/10/Anaf/Informatii_R/API/Oauth_procedura_inregistrare_aplicatii_portal_ANAF.pdf |
| e-Factura Technical Info (MF) | https://mfinante.gov.ro/en/web/efactura/informatii-tehnice |
| e-Factura API Presentation (PDF) | https://mfinante.gov.ro/static/10/eFactura/prezentare%20api%20efactura.pdf |
| e-Factura API Calls (PDF) | https://mfinante.gov.ro/static/10/eFactura/prezentare%20apeluri%20API%20E-factura.pdf |
| e-Factura Endpoint URLs | https://static.anaf.ro/static/10/Anaf/Informatii_R/Servicii_web/url_eFactura.html |
| e-Factura Rate Limits | https://mfinante.gov.ro/static/10/eFactura/limiteApeluriAPI.txt |
| e-Factura Guide (PDF) | https://static.anaf.ro/static/10/Anaf/AsistentaContribuabili_r/Ghid_RO_eFactura.pdf |
| e-Factura Guide 2024 (PDF) | https://static.anaf.ro/static/10/Anaf/AsistentaContribuabili_r/Ghid_e_factura_2024.pdf |
| e-Factura Frequent Errors (PDF) | https://static.anaf.ro/static/10/Anaf/declunica/Erori_frecventev5.pdf |
| e-Factura Presentation (PDF) | https://mfinante.gov.ro/static/10/eFactura/PrezentareE-factura.pdf |
| e-Transport Technical Info | https://etransport.mfinante.gov.ro/informatii-tehnice |
| e-Transport Application Guide (PDF) | https://static.anaf.ro/static/10/Anaf/AsistentaContribuabili_r/Ghid_Aplicatie_eTransport.pdf |
| ANAF Web Services Main Page | https://www.anaf.ro/anaf/internet/ANAF/servicii_online/servicii_web_anaf/ |
| Company Lookup V9 Docs | https://static.anaf.ro/static/10/Anaf/Informatii_R/Servicii_web/doc_WS_V9.txt |
| SPV Documents for Legal Entities (PDF) | https://static.anaf.ro/static/10/Anaf/Informatii_R/SPV/DocumentePJ.pdf |
| e-Factura Main Portal | https://mfinante.gov.ro/en/web/efactura |
| e-TVA Information | https://mfinante.gov.ro/en/web/efactura/e-tva |

### Online Tools

| Tool | URL |
|---|---|
| XML Invoice Validator | https://www.anaf.ro/uploadxmi/ |
| XML to PDF Converter | https://www.anaf.ro/uploadxml |
| Invoice Builder | https://www.anaf.ro/CompletareFactura/faces/factura/informatiigenerale.xhtml |
| e-Factura Portal | https://efactura.mfinante.ro |
| e-Transport Portal | https://etransport.mfinante.gov.ro |

### Authentication Domains Reference

| Domain | Purpose | Auth Type |
|---|---|---|
| `logincert.anaf.ro` | OAuth2 authorization & token endpoints | Digital certificate (initial auth) |
| `api.anaf.ro` | e-Factura & e-Transport API | OAuth2 Bearer token |
| `webserviceapl.anaf.ro` | e-Factura & e-Transport API | TLS client certificate |
| `webservicesp.anaf.ro` | Public APIs (validation, conversion, company lookup) | None |
| `webserviced.anaf.ro` | SPV Web Services (declarations, fiscal data) | TLS client certificate |

---

## 13. Community SDKs & Libraries

### Feature Coverage Matrix

| Repository | Language | Stars | e-Factura | e-Transport | VAT Lookup | OAuth | SPV |
|---|---|---|---|---|---|---|---|
| [printesoi/e-factura-go](https://github.com/printesoi/e-factura-go) | Go | 46 | Full | Yes | Yes | Yes | — |
| [itrack/anaf](https://github.com/itrack/anaf) | PHP | 150 | — | — | Yes | — | — |
| [andalisolutions/anaf-php](https://github.com/andalisolutions/anaf-php) | PHP | 89 | Yes | Planned | Yes | Via companion | Yes |
| [Rebootcodesoft/efactura_anaf](https://github.com/Rebootcodesoft/efactura_anaf) | PHP | 42 | Yes | — | — | Yes | Yes |
| [ClimenteA/PFASimplu](https://github.com/ClimenteA/PFASimplu) | Python | 32 | Yes | — | — | Yes | — |
| [TecsiAron/ANAF-API-Client-PHP](https://github.com/TecsiAron/ANAF-API-Client-PHP) | PHP | 20 | Yes | — | Yes | Yes | Yes |
| [andalisolutions/oauth2-anaf](https://github.com/andalisolutions/oauth2-anaf) | PHP | 18 | — | — | — | Yes | — |
| [florin-szilagyi/efactura-anaf-ts-sdk](https://github.com/florin-szilagyi/efactura-anaf-ts-sdk) | TypeScript | — | Yes | — | — | Yes | — |
| [MfpAnaf/ClientSPV](https://github.com/MfpAnaf/ClientSPV) | Java | — | — | — | — | Cert | Yes (official) |
| [sibies/Anaf.Net](https://github.com/sibies/Anaf.Net) | C# | — | Yes | — | Yes | — | Yes |
| [abcsoft-ro/pyefact](https://github.com/abcsoft-ro/pyefact) | Python | — | Yes | — | — | Yes | Yes |
| [hktr92/anaf-rs](https://github.com/hktr92/anaf-rs) | Rust | — | — | — | Yes | — | Yes |

### Official ANAF Client

- **[MfpAnaf/ClientSPV](https://github.com/MfpAnaf/ClientSPV)** — Official Java client for SPV Web Services. Contact: `spv.webservice@mfinante.ro`

### Notable Community Resources

| Resource | URL |
|---|---|
| ANAF Postman Collection | https://www.postman.com/ovidiuineu/anaf/overview |
| SmartLife ERP Postman Workspace | https://www.postman.com/smartlifeerp/workspace/test-e-fatura/overview |
| TecsiAron PHP Client Docs | https://tecsiaron.github.io/ANAF-API-Client-PHP/ |
| e-Factura Tutorial (licomp.ro) | https://www.licomp.ro/efactura_tutor.aspx |
| Socrate e-Factura API Reference | https://docs.socrate.io/api-reference/ro-efactura-service/ |
| Socrate ANAF OAuth Reference | https://docs.socrate.io/api-reference/ro-anaf-oauth-service/ |
| Contazen API Documentation | https://docs.contazen.ro/concepts/efactura |

---

## Quick Reference Card

### Complete Authentication + Upload + Download Flow

```bash
# 1. Get authorization code (browser redirect — requires digital certificate)
# User visits:
# https://logincert.anaf.ro/anaf-oauth2/v1/authorize?response_type=code&client_id=YOUR_ID&redirect_uri=YOUR_URL&token_content_type=jwt
# → Returns ?code=AUTH_CODE on your redirect URL

# 2. Exchange code for tokens
curl -s -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -d "grant_type=authorization_code&code=AUTH_CODE&client_id=YOUR_ID&client_secret=YOUR_SECRET&redirect_uri=YOUR_URL&token_content_type=jwt"
# → {"access_token":"eyJ...","refresh_token":"eyJ...","expires_in":7776000}

# 3. Upload an invoice
curl -X POST "https://api.anaf.ro/prod/FCTEL/rest/upload?standard=UBL&cif=12345678" \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml
# → <header ... ExecutionStatus="0" index_incarcare="5006096656"/>

# 4. Check processing status
curl "https://api.anaf.ro/prod/FCTEL/rest/stareMesaj?id_incarcare=5006096656" \
  -H "Authorization: Bearer eyJ..."
# → <header ... stare="ok" id_descarcare="3008662942"/>

# 5. Download signed invoice
curl "https://api.anaf.ro/prod/FCTEL/rest/descarcare?id=3008662942" \
  -H "Authorization: Bearer eyJ..." \
  -o signed_invoice.zip

# 6. List received invoices (last 30 days)
curl "https://api.anaf.ro/prod/FCTEL/rest/listaMesajeFactura?zile=30&cif=12345678&filtru=P" \
  -H "Authorization: Bearer eyJ..."

# 7. Refresh token (when access token expires after 90 days)
curl -X POST https://logincert.anaf.ro/anaf-oauth2/v1/token \
  -d "grant_type=refresh_token&refresh_token=eyJ...&client_id=YOUR_ID&client_secret=YOUR_SECRET"

# 8. Validate XML (no auth needed)
curl -X POST "https://webservicesp.anaf.ro/prod/FCTEL/rest/validare/FACT1" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml

# 9. Convert XML to PDF (no auth needed)
curl -X POST "https://webservicesp.anaf.ro/prod/FCTEL/rest/transformare/FACT1/DA" \
  -H "Content-Type: text/plain" \
  --data-binary @invoice.xml \
  -o invoice.pdf

# 10. Look up a company (no auth needed)
curl -X POST https://webservicesp.anaf.ro/api/PlatitorTvaRest/v9/tva \
  -H "Content-Type: application/json" \
  -d '[{"cui":12345678,"data":"2025-01-15"}]'
```
